// SSDM: Temporal Accumulation
//
// Reprojects the previous frame's virtual depth to the current frame using
// matrix-based reprojection (motion vectors not yet available at this pipeline
// stage — SSDM runs before Deferred Composite).
//
// Exponential blend with disocclusion rejection keeps stable virtual depth
// across frames while reacting promptly to disoccluded surfaces.

#include "ScreenSpaceDisplacementMapping/common.hlsli"
#include "Common/VR.hlsli"
#include "Common/GBuffer.hlsli"

// ---------- Inputs -----------------------------------------------------------

Texture2D<float>   texCurrentDepth : register(t0);  // displace output: virtual depth this frame
Texture2D<float>   texHistoryDepth : register(t1);  // temporal output from previous frame
Texture2D<float4>  texNormals      : register(t2);  // NORMALROUGHNESS for disocclusion

// ---------- Outputs ----------------------------------------------------------

RWTexture2D<uint>  rwAccumCount     : register(u0);  // per-pixel frame accumulation counter (R8_UINT)
RWTexture2D<float> outTemporalDepth : register(u1);  // temporal output for this frame

// ---------- Main -------------------------------------------------------------

[numthreads(16, 16, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	uint2 coord = dtid.xy;
	if (any(coord >= uint2(FrameDim)))
		return;

	float2 stereoUV = ((float2)coord + 0.5) * RcpFrameDim;
	uint   eyeIndex = Stereo::GetEyeIndexFromTexCoord(stereoUV);
	float2 screenUV = Stereo::ConvertFromStereoUV(stereoUV, eyeIndex);

	float currDepth = texCurrentDepth[coord];

	// Invalid depth (sky): passthrough, reset accumulation.
	if (currDepth <= 0.0 || currDepth > 1e5) {
		outTemporalDepth[coord] = currDepth;
		rwAccumCount[coord]     = 0;
		return;
	}

	// ---- Reconstruct world-space position from virtual depth ---------------
	float3 P_view  = SSDMScreenToViewPos(screenUV, currDepth, eyeIndex);
	float4 P_world = mul(CurrInvViewMat[eyeIndex], float4(P_view, 1.0));

	// ---- Reproject to previous-frame clip space ----------------------------
	float4 P_prev_clip = mul(PrevViewProjMat[eyeIndex], P_world);

	// Discard if behind previous camera.
	if (P_prev_clip.w <= 1e-5) {
		outTemporalDepth[coord] = currDepth;
		rwAccumCount[coord]     = 1;
		return;
	}

	// NDC → per-eye [0,1] UV (y-axis is inverted between NDC and screen UV).
	float2 prevNDC      = P_prev_clip.xy / P_prev_clip.w;
	float2 prevPerEyeUV = prevNDC * float2(0.5, -0.5) + 0.5;

	if (!SSDMIsValidUV(prevPerEyeUV)) {
		outTemporalDepth[coord] = currDepth;
		rwAccumCount[coord]     = 1;
		return;
	}

	float2 prevStereoUV = Stereo::ConvertToStereoUV(prevPerEyeUV, eyeIndex);

	// ---- Sample history at reprojected UV ----------------------------------
	float histDepth = texHistoryDepth.SampleLevel(samplerLinearClamp, prevStereoUV, 0.0);

	// ---- Disocclusion tests ------------------------------------------------
	// Depth delta: reject when surfaces are further apart than 10% of current depth.
	// This catches disoccluded regions after parallax-induced depth changes.
	bool validDepth = abs(currDepth - histDepth) < (currDepth * 0.1);

	// Normal consistency: if surface orientation changed drastically, reject.
	bool validNormal = true;
	if (validDepth) {
		float3 currNormal = (float3)GBuffer::DecodeNormal(texNormals[coord].xy);
		float3 histNormal = (float3)GBuffer::DecodeNormal(
			texNormals.SampleLevel(samplerPointClamp, prevStereoUV, 0.0).xy);
		validNormal = dot(currNormal, histNormal) > 0.9;
	}

	bool valid = validDepth && validNormal;

	// ---- Accumulation and adaptive blend -----------------------------------
	uint accumCount = valid ? (rwAccumCount[coord] + 1u) : 1u;
	accumCount      = min(accumCount, MaxAccumFrames);
	rwAccumCount[coord] = accumCount;

	// Confidence: 0 on first frame → full trust current; 1 at MaxAccumFrames → MinBlendAlpha.
	float confidence = saturate((float)accumCount / (float)MaxAccumFrames);
	float alpha      = lerp(1.0, MinBlendAlpha, confidence);

	outTemporalDepth[coord] = valid ? lerp(histDepth, currDepth, alpha) : currDepth;
}
