// SSDM: Cross-Bilateral Spatial Denoising
//
// Smooths the temporally-accumulated virtual depth over a small kernel while
// preserving sharp edges. Edge-stopping weights on depth and surface normal
// prevent depth values from bleeding across surface boundaries.
//
// BlurRadius controls kernel half-width (1 = 3×3, 2 = 5×5).
// BlurDepthSigma controls depth edge sensitivity.

#include "ScreenSpaceDisplacementMapping/common.hlsli"
#include "Common/VR.hlsli"
#include "Common/GBuffer.hlsli"

// ---------- Inputs -----------------------------------------------------------

Texture2D<float>   texInputDepth : register(t0);  // temporal output (blur source)
Texture2D<float4>  texNormals    : register(t1);  // NORMALROUGHNESS for edge-stopping

// ---------- Output -----------------------------------------------------------

// Blur output reuses texRefinedDepth[outputIdx] — safe because the displace
// pass already consumed it before temporal ran. Reusing avoids a separate allocation.
RWTexture2D<float> outBlurDepth : register(u0);

// ---------- Main -------------------------------------------------------------

[numthreads(16, 16, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	uint2 coord = dtid.xy;
	if (any(coord >= uint2(FrameDim)))
		return;

	float  centerDepth  = texInputDepth[coord];
	float3 centerNormal = (float3)GBuffer::DecodeNormal(texNormals[coord].xy);

	float totalWeight = 1.0;
	float totalDepth  = centerDepth;

	int r = (int)clamp((int)BlurRadius, 1, 3);

	[loop]
	for (int dy = -r; dy <= r; ++dy) {
		[loop]
		for (int dx = -r; dx <= r; ++dx) {
			if (dx == 0 && dy == 0)
				continue;

			int2   sCoord = (int2)coord + int2(dx, dy);
			float2 sUV    = ((float2)sCoord + 0.5) * RcpFrameDim;

			if (!SSDMIsValidUV(sUV))
				continue;

			float  sDepth  = texInputDepth[sCoord];
			float3 sNormal = (float3)GBuffer::DecodeNormal(texNormals[sCoord].xy);

			// Gaussian spatial weight.
			float spatialDist = sqrt((float)(dx * dx + dy * dy));
			float wSpatial    = exp(-spatialDist * spatialDist * 0.5);

			// Depth edge-stopping: samples close in depth to center get high weight.
			float depthDelta = abs(sDepth - centerDepth);
			float wDepth     = exp(-depthDelta * depthDelta /
			                       (2.0 * BlurDepthSigma * BlurDepthSigma + 1e-6));

			// Normal edge-stopping: samples on similar surface orientation are trusted.
			float NdotN   = saturate(dot(centerNormal, sNormal));
			float wNormal = pow(NdotN, 8.0);

			float w = wSpatial * wDepth * wNormal;
			totalWeight += w;
			totalDepth  += sDepth * w;
		}
	}

	outBlurDepth[coord] = totalDepth / totalWeight;
}
