//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************

// ToDo
// Desc: Filters invalid values from neighborhood via gaussian filter.
// Supports up to 9x9 kernels.
// Requirements:
// - wave lane size 16 or higher.
// Performance: 
// ToDo:

#define HLSL
#include "RaytracingHlslCompat.h"
#include "RaytracingShaderHelper.hlsli"
#include "RTAO/Shaders/RTAO.hlsli"

#define GAUSSIAN_KERNEL_5X5
#include "Kernels.hlsli"

Texture2D<float> g_inValues : register(t0);
Texture2D<float> g_inDepths : register(t1);
RWTexture2D<float> g_outValues : register(u0);

ConstantBuffer<FilterConstantBuffer> cb: register(b0);

// Group shared memory cache for the row aggregated results.
// ToDo parameterize SMEM based on kernel dims.
groupshared uint PackedValuesDepthsCache[16][8];         // 16bit float value, depth.
groupshared uint PackedRowResultCache[16][8];            // 16bit float weightedValueSum, weightSum.

uint2 GetPixelIndex(in uint2 Gid, in uint2 GTid)
{
    // Find a DTID with steps in between the group threads and groups interleaved to cover all pixels.
    uint2 GroupDim = uint2(8, 8);
    uint2 groupBase = (Gid / cb.step) * cb.step * GroupDim + Gid % cb.step;
    uint2 groupThreadOffset = GTid * cb.step;
    uint2 sDTid = groupBase + groupThreadOffset;

    return sDTid;
}

// Load up to 16x16 pixels and filter them horizontally.
// The output is cached in Shared Memory and contains NumRows x 8 results.
void FilterHorizontally(in uint2 Gid, in uint GI)
{
    const uint2 GroupDim = uint2(8, 8);
    const uint NumValuesToLoadPerRowOrColumn = GroupDim.x + (FilterKernel::Width - 1);

    // Process the thread group as row-major 16x4, where each sub group of 16 threads processes one row.
    // Each thread loads up to 4 values, with the sub groups loading rows interleaved.
    // Loads up to 16x4x4 == 256 input values.
    // ToDo rename to 4x16
    uint2 GTid16x4_row0 = uint2(GI % 16, GI / 16);
    int2 KernelBasePixel = GetPixelIndex(Gid, 0) - int(FilterKernel::Radius * cb.step);
    const uint NumRowsToLoadPerThread = 4;
    const uint Row_BaseWaveLaneIndex = (WaveGetLaneIndex() / 16) * 16;

    // ToDo load 8x8 center values to cache and skip if none of the values are missing.
    // ToDo blend low frame age values too with a falloff?

    [unroll]
    for (uint i = 0; i < NumRowsToLoadPerThread; i++)
    {
        uint2 GTid16x4 = GTid16x4_row0 + uint2(0, i * 4);
        if (GTid16x4.y >= NumValuesToLoadPerRowOrColumn)
        {
            break;
        }

        // Load all the contributing columns for each row.
        int2 pixel = KernelBasePixel + GTid16x4 * cb.step;
        float value = RTAO::InvalidAOValue;
        float depth = 0;

        // The lane is out of bounds of the GroupDim + kernel, 
        // but could be within bounds of the input texture,
        // so don't read it from the texture.
        // However, we need to keep it as an active lane for a below split sum.
        if (GTid16x4.x < NumValuesToLoadPerRowOrColumn && IsWithinBounds(pixel, cb.textureDim))
        {
            if (IsInRange(GTid16x4.x, FilterKernel::Radius, FilterKernel::Radius + GroupDim.x - 1) &&
                IsInRange(GTid16x4.y, FilterKernel::Radius, FilterKernel::Radius + GroupDim.y - 1))
            {
                float2 valueDepth = HalfToFloat2(PackedValuesDepthsCache[GTid16x4.y][GTid16x4.x - FilterKernel::Radius]);
                value = valueDepth.x;
            }
            else
            {
                value = g_inValues[pixel];
            }

            depth = g_inDepths[pixel];
        }

        // Cache the kernel center values.
        if (IsInRange(GTid16x4.x, FilterKernel::Radius, FilterKernel::Radius + GroupDim.x - 1))
        {
            PackedValuesDepthsCache[GTid16x4.y][GTid16x4.x - FilterKernel::Radius] = Float2ToHalf(float2(value, depth));
        }

#if RTAO_MARK_CACHED_VALUES_NEGATIVE
        if (value != RTAO::InvalidAOValue)
        {
            value = abs(value);
        }
#endif

        // Filter the values for the first GroupDim columns.
        {
            // Accumulate for the whole kernel width.
            float weightedValueSum = 0;
            float weightSum = 0;

            // Since a row uses 16 lanes, but we only need to calculate the aggregate for the first half (8) lanes,
            // split the kernel wide aggregation among the first 8 and the second 8 lanes, and then combine them.


            // Get the lane index that has the first value for a kernel in this lane.
            uint Row_KernelStartLaneIndex =
                (Row_BaseWaveLaneIndex + GTid16x4.x)
                - (GTid16x4.x < GroupDim.x
                    ? 0
                    : GroupDim.x);

            // Get values for the kernel center.
            uint kcLaneIndex = Row_KernelStartLaneIndex + FilterKernel::Radius;
            float kcValue = WaveReadLaneAt(value, kcLaneIndex);
            float kcDepth = WaveReadLaneAt(depth, kcLaneIndex);

            // Initialize the first 8 lanes to the center cell contribution of the kernel. 
            // This covers the remainder of 1 in FilterKernel::Width / 2 used in the loop below. 
            if (GTid16x4.x < GroupDim.x && kcValue != RTAO::InvalidAOValue && kcDepth != 0)
            {
                float w = FilterKernel::Kernel1D[FilterKernel::Radius];
                weightedValueSum = w * kcValue;
                weightSum = w;
            }

            // Second 8 lanes start just past the kernel center.
            uint KernelCellIndexOffset =
                GTid16x4.x < GroupDim.x
                ? 0
                : (FilterKernel::Radius + 1); // Skip over the already accumulated center cell of the kernel.


            // For all columns in the kernel.
            for (uint c = 0; c < FilterKernel::Radius; c++)
            {
                uint kernelCellIndex = KernelCellIndexOffset + c;

                uint laneToReadFrom = Row_KernelStartLaneIndex + kernelCellIndex;
                float cValue = WaveReadLaneAt(value, laneToReadFrom);
                float cDepth = WaveReadLaneAt(depth, laneToReadFrom);

                if (cValue != RTAO::InvalidAOValue && kcDepth != 0 && cDepth != 0)
                {
                    float w = FilterKernel::Kernel1D[kernelCellIndex];

                    float depthThreshold = 0.01 + cb.step * 0.001 * abs(int(FilterKernel::Radius) - c);
                    float w_d = abs(kcDepth - cDepth) <= depthThreshold * kcDepth;
                    w *= w_d;

                    weightedValueSum += w * cValue;
                    weightSum += w;
                }
            }

            // Combine the sub-results.
            uint laneToReadFrom = min(WaveGetLaneCount() - 1, Row_BaseWaveLaneIndex + GTid16x4.x + GroupDim.x);
            weightedValueSum += WaveReadLaneAt(weightedValueSum, laneToReadFrom);
            weightSum += WaveReadLaneAt(weightSum, laneToReadFrom);

            // Store only the valid results, i.e. first GroupDim columns.
            if (GTid16x4.x < GroupDim.x)
            {
                // ToDo offset row start by rowIndex to avoid bank conflicts on read
                PackedRowResultCache[GTid16x4.y][GTid16x4.x] = Float2ToHalf(float2(weightedValueSum, weightSum));
            }
        }
    }
}

void FilterVertically(uint2 DTid, in uint2 GTid)
{
    float2 kcValueDepth = HalfToFloat2(PackedValuesDepthsCache[GTid.y + FilterKernel::Radius][GTid.x]);
    float kcValue = kcValueDepth.x;
    float kcDepth = kcValueDepth.y;

    float filteredValue = kcValue;

    if (kcValue == RTAO::InvalidAOValue && kcDepth != 0)
    {
        float weightedValueSum = 0;
        float weightSum = 0;

        // For all rows in the kernel.
        // ToDo Unroll
        for (uint r = 0; r < FilterKernel::Width; r++)
        {
            uint rowID = GTid.y + r;

            float2 rUnpackedValueDepth = HalfToFloat2(PackedValuesDepthsCache[rowID][GTid.x]);
            float rDepth = rUnpackedValueDepth.y;

            if (rDepth != 0)
            {
                float2 rUnpackedRowResult = HalfToFloat2(PackedRowResultCache[rowID][GTid.x]);
                float rWeightedValueSum = rUnpackedRowResult.x;
                float rWeightSum = rUnpackedRowResult.y;

                float w = FilterKernel::Kernel1D[r];
                float depthThreshold = 0.01 + cb.step * 0.001 * abs(int(FilterKernel::Radius) - int(r));
                float w_d = abs(kcDepth - rDepth) <= depthThreshold * kcDepth;
                w *= w_d;

                weightedValueSum += w * rWeightedValueSum;
                weightSum += w * rWeightSum;
            }
        }

        filteredValue = weightSum > 1e-9 ? weightedValueSum / weightSum : RTAO::InvalidAOValue;
#if RTAO_MARK_CACHED_VALUES_NEGATIVE
        filteredValue = filteredValue != RTAO::InvalidAOValue && kcValue < 0 ? -filteredValue : filteredValue;
#endif
    }

    g_outValues[DTid] = filteredValue;
}


[numthreads(DefaultComputeShaderParams::ThreadGroup::Width, DefaultComputeShaderParams::ThreadGroup::Height, 1)]
void main(uint2 Gid : SV_GroupID, uint2 GTid : SV_GroupThreadID, uint GI : SV_GroupIndex)
{
    uint2 sDTid = GetPixelIndex(Gid, GTid);

    // Pass through if there are no missing values in this group thread block.
    {
        if (GI == 0)
            PackedRowResultCache[0][0] = 0;
        GroupMemoryBarrierWithGroupSync();

        float value = IsWithinBounds(sDTid, cb.textureDim) ? g_inValues[sDTid] : RTAO::InvalidAOValue;
        bool valueNeedsFiltering = value == RTAO::InvalidAOValue;
        if (valueNeedsFiltering)
            PackedRowResultCache[0][0] = 1;

        PackedValuesDepthsCache[GTid.y + FilterKernel::Radius][GTid.x] = Float2ToHalf(float2(value, 0));
        GroupMemoryBarrierWithGroupSync();

        if (PackedRowResultCache[0][0] == 0)
        {
            g_outValues[sDTid] = value;
            return;
        }
    }
    FilterHorizontally(Gid, GI);
    GroupMemoryBarrierWithGroupSync();

    FilterVertically(sDTid, GTid);
}
