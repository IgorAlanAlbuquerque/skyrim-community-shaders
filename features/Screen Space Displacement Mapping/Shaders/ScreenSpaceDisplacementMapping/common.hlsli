#ifndef SSDM_COMMON
#define SSDM_COMMON

#include "Common/Math.hlsli"
#include "Common/SharedData.hlsli"

// Constant buffer — must match ScreenSpaceDisplacementMapping::SSDMCB in C++.
// C++ float2[2] maps to HLSL float4 (same 16-byte layout, xy=eye0, zw=eye1).
cbuffer SSDMCB : register(b1)
{
	float4x4 PrevInvViewMat[2];   // previous frame cam-to-world (for disocclusion validation)
	float4x4 CurrInvViewMat[2];   // current frame cam-to-world  (view-space → world)
	float4x4 PrevViewProjMat[2];  // previous frame view × proj   (world → prev clip, for reprojection)
	float4   NDCToViewMul;        // xy = eye 0, zw = eye 1
	float4   NDCToViewAdd;        // xy = eye 0, zw = eye 1
	float2   TexDim;
	float2   RcpTexDim;
	float2   FrameDim;
	float2   RcpFrameDim;
	uint     FrameIndex;
	float    DisplacementScale;
	float    MaxDisplacementDist;
	float    FadeAngleCos;
	uint     NumRaymarchSteps;
	uint     NumBinarySearchSteps;
	uint     ResolutionMode;
	float    MinBlendAlpha;
	uint     MaxAccumFrames;
	uint     BlurRadius;
	float    BlurDepthSigma;
	float    pad[5];
};

SamplerState samplerPointClamp  : register(s0);
SamplerState samplerLinearClamp : register(s1);

///////////////////////////////////////////////////////////////////////////////
// Depth conversion

// Convert raw NDC depth (0..1 in DX) to view-space Z (positive = in front of camera).
float SSDMRawToLinearDepth(float rawDepth)
{
	return (SharedData::CameraData.w / (-rawDepth * SharedData::CameraData.z + SharedData::CameraData.x));
}

///////////////////////////////////////////////////////////////////////////////
// Space conversions

// Reconstruct view-space position from per-eye screen UV [0,1] and linear (view-space) depth.
// Matches SSGI's ScreenToViewPosition convention.
float3 SSDMScreenToViewPos(float2 screenUV, float linearDepth, uint eyeIndex)
{
	float2 _mul = eyeIndex == 0 ? NDCToViewMul.xy : NDCToViewMul.zw;
	float2 _add = eyeIndex == 0 ? NDCToViewAdd.xy : NDCToViewAdd.zw;
	float3 pos;
	pos.xy = (_mul * screenUV + _add) * linearDepth;
	pos.z  = linearDepth;
	return pos;
}

// Project view-space position back to per-eye screen UV [0,1].
// Inverse of SSDMScreenToViewPos.
float2 SSDMViewPosToScreenUV(float3 viewPos, uint eyeIndex)
{
	float2 _mul = eyeIndex == 0 ? NDCToViewMul.xy : NDCToViewMul.zw;
	float2 _add = eyeIndex == 0 ? NDCToViewAdd.xy : NDCToViewAdd.zw;
	return (viewPos.xy / viewPos.z - _add) / _mul;
}

// Returns true when the UV is within [0,1]×[0,1] screen bounds.
bool SSDMIsValidUV(float2 uv)
{
	return all(uv >= 0.0) && all(uv <= 1.0);
}

// Conservative depth test: true when sampleDepth is ≥ rayDepth minus thickness.
// sampleDepth and rayDepth must be in view-space (linear, positive = in front).
bool SSDMDepthTest(float sampleDepth, float rayDepth, float thickness)
{
	return sampleDepth >= (rayDepth - thickness) && sampleDepth <= rayDepth;
}

///////////////////////////////////////////////////////////////////////////////
// World-space helpers (from SSGI's common.hlsli)

float3 SSDMViewToWorldPos(float3 viewPos, float4x4 invView)
{
	float4 wp = mul(invView, float4(viewPos, 1.0));
	return wp.xyz / wp.w;
}

float3 SSDMViewToWorldVec(float3 viewVec, float4x4 invView)
{
	return mul((float3x3)invView, viewVec);
}

#endif // SSDM_COMMON
