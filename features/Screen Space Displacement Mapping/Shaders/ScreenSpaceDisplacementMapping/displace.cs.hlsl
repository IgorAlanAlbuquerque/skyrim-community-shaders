// SSDM: Screen-Space Displacement Mapping — ray-march compute shader.
//
// For each pixel carrying parallax height (H > 0 in the HeightGBuffer B channel),
// marches a view-space ray from the mesh surface toward the camera through the
// conservative depth pyramid, searching for displaced geometry in the depth buffer.
//
// Output: virtual linear depth written to u0, consumed by SSAO/SSGI in Task 7.
// Pixels with parallax but no ray-march hit receive a simple H-based depth offset,
// ensuring flat parallax surfaces still produce a meaningful virtual depth.
// Pixels without parallax receive the original depth (passthrough).

#include "ScreenSpaceDisplacementMapping/common.hlsli"
#include "Common/VR.hlsli"
#include "Common/GBuffer.hlsli"

// ---------- Inputs -----------------------------------------------------------

Texture2D<float>  texSceneDepth      : register(t0);  // full-res raw NDC depth (0=far, 1=near)
Texture2D<float4> texNormalRoughness : register(t1);  // NORMALROUGHNESS GBuffer (R10G10B10A2)
Texture2D<float4> texHeightGBuffer   : register(t2);  // ExtendedMaterials RGBA16: B = parallax height [0,1]
Texture2D<float>  texDepthHierarchy  : register(t3);  // 5-mip conservative linear depth (mip0 = half-res)

// ---------- Output -----------------------------------------------------------

// View-space linear depth of the apparent displaced surface.
// Smaller than original depth → surface appears raised (closer to camera).
// Equal to original depth → no displacement (flat surface or passthrough).
RWTexture2D<float> outVirtualDepth : register(u0);

// ---------- Main -------------------------------------------------------------

[numthreads(16, 16, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	uint2 coord = dtid.xy;

	// Guard against dispatch overshoot (dispatch rounds up).
	if (any(coord >= uint2(FrameDim)))
		return;

	float2 stereoUV = ((float2)coord + 0.5) * RcpFrameDim;
	uint   eyeIndex = Stereo::GetEyeIndexFromTexCoord(stereoUV);
	float2 screenUV = Stereo::ConvertFromStereoUV(stereoUV, eyeIndex);  // per-eye [0,1]

	// ---- Read and validate depth -------------------------------------------
	float rawDepth    = texSceneDepth[coord];
	float linearDepth = SSDMRawToLinearDepth(rawDepth);

	// Reject sky and degenerate depths — passthrough, no virtual displacement.
	if (linearDepth <= 0.0 || linearDepth > 1e5) {
		outVirtualDepth[coord] = linearDepth;
		return;
	}

	// ---- Early exit: no parallax height ------------------------------------
	float H = texHeightGBuffer[coord].b;
	if (H < 0.005) {
		outVirtualDepth[coord] = linearDepth;
		return;
	}

	// ---- Reconstruct view-space position -----------------------------------
	float3 P = SSDMScreenToViewPos(screenUV, linearDepth, eyeIndex);

	// ---- Decode view-space surface normal ----------------------------------
	float4 normalData = texNormalRoughness[coord];
	float3 normalVS   = (float3)GBuffer::DecodeNormal(normalData.xy);

	// ---- Angle fade (suppress at grazing incidence) ------------------------
	float3 V     = normalize(-P);              // from surface toward camera
	float  NdotV = saturate(dot(normalVS, V));

	if (NdotV < FadeAngleCos) {
		outVirtualDepth[coord] = linearDepth;
		return;
	}

	float angleFade = saturate((NdotV - FadeAngleCos) /
	                            max(1.0e-4, 1.0 - FadeAngleCos));

	// ---- Ray setup ---------------------------------------------------------
	// D_max: maximum view-space displacement toward camera.
	float  D_max   = H * DisplacementScale * MaxDisplacementDist * angleFade;
	uint   nSteps  = max(1u, NumRaymarchSteps);
	float3 stepVec = V * (D_max / (float)nSteps);

	// Start one step in from the mesh surface to avoid self-intersection.
	float3 rayPos  = P + stepVec;
	float3 prevPos = P;

	float hitDepth = 0;
	bool  hit      = false;

	// ---- Linear march through depth hierarchy ------------------------------
	// Marches toward camera (decreasing linearDepth). Fires when a screen
	// position is found where the scene depth equals the ray depth —
	// i.e., the ray intersects existing geometry at the displaced screen UV.
	[loop]
	for (uint i = 0; i < nSteps; ++i) {
		float2 stepPerEyeUV = SSDMViewPosToScreenUV(rayPos, eyeIndex);

		if (!SSDMIsValidUV(stepPerEyeUV))
			break;

		float2 stepStereoUV = Stereo::ConvertToStereoUV(stepPerEyeUV, eyeIndex);
		float  hierDepth    = texDepthHierarchy.SampleLevel(samplerLinearClamp, stepStereoUV, 0.0);

		// Thickness: 2% of view-space depth to handle depth buffer precision.
		float thickness = rayPos.z * 0.02;

		if (SSDMDepthTest(hierDepth, rayPos.z, thickness)) {
			hitDepth = rayPos.z;
			hit      = true;
			break;
		}

		prevPos = rayPos;
		rayPos += stepVec;
	}

	// ---- Binary search refinement (between last-miss and first-hit) --------
	if (hit && NumBinarySearchSteps > 0) {
		float3 lo = prevPos;
		float3 hi = rayPos;

		[loop]
		for (uint j = 0; j < NumBinarySearchSteps; ++j) {
			float3 mid         = (lo + hi) * 0.5;
			float2 midPerEyeUV = SSDMViewPosToScreenUV(mid, eyeIndex);
			float2 midStereoUV = Stereo::ConvertToStereoUV(midPerEyeUV, eyeIndex);
			float  midDepth    = texDepthHierarchy.SampleLevel(samplerLinearClamp, midStereoUV, 0.0);
			float  thickness   = mid.z * 0.02;

			if (SSDMDepthTest(midDepth, mid.z, thickness)) {
				hi       = mid;
				hitDepth = mid.z;
			} else {
				lo = mid;
			}
		}
	}

	// ---- Output ------------------------------------------------------------
	// Ray-march hit: refined depth from actual scene geometry at displaced position.
	// No hit: simple H-based depth offset so flat parallax surfaces still produce
	// a meaningful virtual depth for SSAO/SSGI (raised areas appear closer to camera).
	if (hit) {
		outVirtualDepth[coord] = hitDepth;
	} else {
		// linearDepth - D_max: raised surface (H→1) appears closer to camera (smaller depth).
		outVirtualDepth[coord] = max(1e-4, linearDepth - D_max);
	}
}
