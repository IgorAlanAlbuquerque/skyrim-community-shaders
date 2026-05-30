// SSDM: Depth Hierarchy Pre-filter
// Builds a 5-level conservative (max) mip pyramid from the full-res NDC depth buffer.
// Output mip 0 is at half-resolution; each subsequent mip halves again.
// MAX filter ensures no ray-march step misses thin geometry.
//
// Follows the same single-dispatch groupshared approach as SSGI/prefilterDepths.cs.hlsl.
// Each thread writes a 2×2 block of mip-0 pixels (one GatherRed per pixel),
// then the 8×8 groupshared block is reduced for mips 1-4.

#include "ScreenSpaceDisplacementMapping/common.hlsli"

Texture2D<float>    srcDepth  : register(t0);   // full-res NDC depth (0=far, 1=near in DX)

// Five per-mip UAVs bound at the five mip slices of texDepthHierarchy.
RWTexture2D<float>  outDepth0 : register(u0);   // mip 0 — half res
RWTexture2D<float>  outDepth1 : register(u1);   // mip 1
RWTexture2D<float>  outDepth2 : register(u2);   // mip 2
RWTexture2D<float>  outDepth3 : register(u3);   // mip 3
RWTexture2D<float>  outDepth4 : register(u4);   // mip 4

groupshared float g_depths[8][8];

// Conservative max of four raw depth samples converted to view-space.
float SampleMaxLinearDepth(uint2 fullCoord)
{
	float d0 = SSDMRawToLinearDepth(srcDepth[fullCoord + uint2(0, 0)]);
	float d1 = SSDMRawToLinearDepth(srcDepth[fullCoord + uint2(1, 0)]);
	float d2 = SSDMRawToLinearDepth(srcDepth[fullCoord + uint2(0, 1)]);
	float d3 = SSDMRawToLinearDepth(srcDepth[fullCoord + uint2(1, 1)]);
	return max(max(d0, d1), max(d2, d3));
}

// Dispatch: (halfWidth/2 + 7)/8 × (halfHeight/2 + 7)/8
// Each thread covers a 2×2 block in mip-0 (half-res) → 4×4 block in full-res.
[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID, uint2 gtid : SV_GroupThreadID)
{
	// --- MIP 0 ---------------------------------------------------------------
	// dtid.xy indexes the mip-1 space. Each thread writes a 2×2 tile of mip-0.
	const uint2 mip0Base = dtid.xy * 2;
	const uint2 fullBase = mip0Base * 2;

	float d00 = SampleMaxLinearDepth(fullBase + uint2(0, 0));
	float d10 = SampleMaxLinearDepth(fullBase + uint2(2, 0));
	float d01 = SampleMaxLinearDepth(fullBase + uint2(0, 2));
	float d11 = SampleMaxLinearDepth(fullBase + uint2(2, 2));

	outDepth0[mip0Base + uint2(0, 0)] = d00;
	outDepth0[mip0Base + uint2(1, 0)] = d10;
	outDepth0[mip0Base + uint2(0, 1)] = d01;
	outDepth0[mip0Base + uint2(1, 1)] = d11;

	// --- MIP 1 ---------------------------------------------------------------
	float dm1 = max(max(d00, d10), max(d01, d11));
	outDepth1[dtid.xy] = dm1;
	g_depths[gtid.x][gtid.y] = dm1;

	GroupMemoryBarrierWithGroupSync();

	// --- MIP 2 ---------------------------------------------------------------
	[branch]
	if (all((gtid.xy % 2) == 0))
	{
		float inTL = g_depths[gtid.x + 0][gtid.y + 0];
		float inTR = g_depths[gtid.x + 1][gtid.y + 0];
		float inBL = g_depths[gtid.x + 0][gtid.y + 1];
		float inBR = g_depths[gtid.x + 1][gtid.y + 1];
		float dm2  = max(max(inTL, inTR), max(inBL, inBR));
		outDepth2[dtid.xy / 2]         = dm2;
		g_depths[gtid.x][gtid.y]       = dm2;
	}

	GroupMemoryBarrierWithGroupSync();

	// --- MIP 3 ---------------------------------------------------------------
	[branch]
	if (all((gtid.xy % 4) == 0))
	{
		float inTL = g_depths[gtid.x + 0][gtid.y + 0];
		float inTR = g_depths[gtid.x + 2][gtid.y + 0];
		float inBL = g_depths[gtid.x + 0][gtid.y + 2];
		float inBR = g_depths[gtid.x + 2][gtid.y + 2];
		float dm3  = max(max(inTL, inTR), max(inBL, inBR));
		outDepth3[dtid.xy / 4]         = dm3;
		g_depths[gtid.x][gtid.y]       = dm3;
	}

	GroupMemoryBarrierWithGroupSync();

	// --- MIP 4 ---------------------------------------------------------------
	[branch]
	if (all((gtid.xy % 8) == 0))
	{
		float inTL = g_depths[gtid.x + 0][gtid.y + 0];
		float inTR = g_depths[gtid.x + 4][gtid.y + 0];
		float inBL = g_depths[gtid.x + 0][gtid.y + 4];
		float inBR = g_depths[gtid.x + 4][gtid.y + 4];
		float dm4  = max(max(inTL, inTR), max(inBL, inBR));
		outDepth4[dtid.xy / 8]         = dm4;
	}
}
