// SSDM: Screen Space Displacement Mapping
// Replaces per-pixel parallax occlusion mapping with a screen-space approach.
// The forward pass writes displacement vectors to a UAV; compute passes
// refine them hierarchically before DeferredComposite.

#if defined(TERRAIN_VARIATION) && defined(LANDSCAPE)
#	include "TerrainVariation/TerrainVariation.hlsli"
#endif

struct DisplacementParams
{
	float DisplacementScale;
	float DisplacementOffset;
	float HeightScale;
	float FlattenAmount;
};

namespace ExtendedMaterials
{
	float ScaleDisplacement(float displacement, DisplacementParams params)
	{
		return (displacement - 0.5) * params.HeightScale;
	}

	float AdjustDisplacementNormalized(float displacement, DisplacementParams params)
	{
		return (displacement - 0.5) * params.DisplacementScale + 0.5 + params.DisplacementOffset;
	}

	float4 AdjustDisplacementNormalized(float4 displacement, DisplacementParams params)
	{
		return float4(AdjustDisplacementNormalized(displacement.x, params), AdjustDisplacementNormalized(displacement.y, params), AdjustDisplacementNormalized(displacement.z, params), AdjustDisplacementNormalized(displacement.w, params));
	}

	float ComputeMipLevelAnisotropic(float2 coords, Texture2D<float4> tex)
	{
		float2 textureDims;
		tex.GetDimensions(textureDims.x, textureDims.y);

#if !defined(PARALLAX) && !defined(TRUE_PBR)
		textureDims /= 2.0;
#endif

#if defined(VR)
		textureDims /= 2.0;
#endif

		float2 texCoordsPerSize = coords * textureDims;

		float2 dxSize = ddx(texCoordsPerSize);
		float2 dySize = ddy(texCoordsPerSize);

		float minTexCoordDelta = min(dot(dxSize, dxSize), dot(dySize, dySize));
		float mipLevel = max(0.5 * log2(minTexCoordDelta), 0);

#if !defined(PARALLAX) && !defined(TRUE_PBR)
		mipLevel++;
#endif

#if defined(VR)
		mipLevel++;
#endif

		return mipLevel;
	}

	// Same as ComputeMipLevelAnisotropic but uses max(ddx², ddy²) instead of min.
	// For shading, min avoids blurrier-than-needed filtering; for SSDM height, min picks the
	// axis with almost no UV change at grazing angles → mip 0 → aliased height and broken UV offsets.
	float ComputeMipLevelAnisotropicDisplacement(float2 coords, Texture2D<float4> tex)
	{
		float2 textureDims;
		tex.GetDimensions(textureDims.x, textureDims.y);

#if !defined(PARALLAX) && !defined(TRUE_PBR)
		textureDims /= 2.0;
#endif

#if defined(VR)
		textureDims /= 2.0;
#endif

		float2 texCoordsPerSize = coords * textureDims;

		float2 dxSize = ddx(texCoordsPerSize);
		float2 dySize = ddy(texCoordsPerSize);

		float texCoordDelta = max(dot(dxSize, dxSize), dot(dySize, dySize));
		float mipLevel = max(0.5 * log2(texCoordDelta), 0);

#if !defined(PARALLAX) && !defined(TRUE_PBR)
		mipLevel++;
#endif

#if defined(VR)
		mipLevel++;
#endif

		return mipLevel;
	}

	float GetMipLevel(float2 coords, Texture2D<float4> tex, float screenNoise)
	{
		float mipLevel = ComputeMipLevelAnisotropic(coords, tex);
		mipLevel = floor(mipLevel) + (screenNoise < frac(mipLevel) ? 1.0 : 0.0);
		return mipLevel;
	}

	// SSDM / relief height must not use per-pixel mip dither (screenNoise vs frac); that makes
	// adjacent pixels sample different mips and reads as noise or swirls in the displacement field.
	float GetMipLevelForDisplacement(float2 coords, Texture2D<float4> tex)
	{
		float mipLevel = ComputeMipLevelAnisotropicDisplacement(coords, tex);
		// EMAT slider must not jump height mips in whole steps — floor(log2(mult)) made peaks slide in UV vs
		// albedo and SSDM read as texture scrolling when changing displacement intensity.
#	if defined(EMAT)
		float ds = max(SharedData::extendedMaterialSettings.DisplacementScale, 0.08);
		float mipNudge = 0.32 * max(0.0, log2(clamp(ds / 0.05, 1.0, 8.0)));
		float m = max(floor(mipLevel + 0.5 + mipNudge), 0);
#	else
		float m = max(floor(mipLevel + 0.5), 0);
#	endif
		return min(m, 6);
	}

#if defined(LANDSCAPE)
#	define HEIGHT_POWER 2
#	define HEIGHT_MULT 8

	void ProcessTerrainHeightWeights(float heightBlend, float4 w1, float2 w2, float heights[6], inout float weights[6], out float totalHeight)
	{
		weights[0] = w1.x;
		weights[1] = w1.y;
		weights[2] = w1.z;
		weights[3] = w1.w;
		weights[4] = w2.x;
		weights[5] = w2.y;

		totalHeight = 0;
		[unroll] for (int i = 0; i < 6; i++)
		{
			totalHeight += heights[i] * weights[i];
			weights[i] *= pow(heightBlend, HEIGHT_MULT * heights[i]);
		}

		[unroll] for (int j = 0; j < 6; j++)
		{
			weights[j] = min(100, pow(abs(weights[j]), heightBlend));
		}

		float wsum = 0;
		[unroll] for (int k = 0; k < 6; k++)
		{
			wsum += weights[k];
		}

		float invwsum = rcp(wsum);
		[unroll] for (int l = 0; l < 6; l++)
		{
			weights[l] *= invwsum;
		}
	}

#	if defined(TRUE_PBR)
	float GetTerrainHeight(float screenNoise, PS_INPUT input, float2 coords, float mipLevels[6], DisplacementParams params[6], float blendFactor, float4 w1, float2 w2,
#		if defined(TERRAIN_VARIATION)
		StochasticOffsets sharedOffset, float2 dx, float2 dy,
#		endif
		out float weights[6])
	{
		float heightBlend = 1 + blendFactor * HEIGHT_POWER;
		float heights[6] = { 0, 0, 0, 0, 0, 0 };

		// ddx/ddy inside GetMipLevelForDisplacement must not run inside per-pixel branches (PBR flags / blend
		// differ across a 2x2 quad) — derivatives become undefined → random mips → swirly SSDM.
		float mipD0 = GetMipLevelForDisplacement(coords, TexLandDisplacement0Sampler);
		float mipC0 = GetMipLevelForDisplacement(coords, TexColorSampler);
		float mipD1 = GetMipLevelForDisplacement(coords, TexLandDisplacement1Sampler);
		float mipC1 = GetMipLevelForDisplacement(coords, TexLandColor2Sampler);
		float mipD2 = GetMipLevelForDisplacement(coords, TexLandDisplacement2Sampler);
		float mipC2 = GetMipLevelForDisplacement(coords, TexLandColor3Sampler);
		float mipD3 = GetMipLevelForDisplacement(coords, TexLandDisplacement3Sampler);
		float mipC3 = GetMipLevelForDisplacement(coords, TexLandColor4Sampler);
		float mipD4 = GetMipLevelForDisplacement(coords, TexLandDisplacement4Sampler);
		float mipC4 = GetMipLevelForDisplacement(coords, TexLandColor5Sampler);
		float mipD5 = GetMipLevelForDisplacement(coords, TexLandDisplacement5Sampler);
		float mipC5 = GetMipLevelForDisplacement(coords, TexLandColor6Sampler);

		// Match diffuse terrain variation: height taps must use the same hashed offsets (StochasticEffectParallax),
		// not bare patch UV, or SSDM / relief sit on the wrong height features when tiling fix is on.
#		if defined(TERRAIN_VARIATION)
#			define EMAT_LAND_HMAP(tex, mip) StochasticEffectParallax(tex, SampTerrainParallaxSampler, coords, mip, sharedOffset, dx, dy)
#		else
#			define EMAT_LAND_HMAP(tex, mip) tex.SampleLevel(SampTerrainParallaxSampler, coords, mip)
#		endif

		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile0HasDisplacement) != 0 && w1.x > 0.01)
		{
			heights[0] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandDisplacement0Sampler, mipD0).x, params[0]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile0PBR) != 0 && w1.x > 0.01)
		{
			heights[0] = ScaleDisplacement(EMAT_LAND_HMAP(TexColorSampler, mipC0).w, params[0]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile1HasDisplacement) != 0 && w1.y > 0.01)
		{
			heights[1] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandDisplacement1Sampler, mipD1).x, params[1]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile1PBR) != 0 && w1.y > 0.01)
		{
			heights[1] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor2Sampler, mipC1).w, params[1]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile2HasDisplacement) != 0 && w1.z > 0.01)
		{
			heights[2] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandDisplacement2Sampler, mipD2).x, params[2]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile2PBR) != 0 && w1.z > 0.01)
		{
			heights[2] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor3Sampler, mipC2).w, params[2]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile3HasDisplacement) != 0 && w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandDisplacement3Sampler, mipD3).x, params[3]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile3PBR) != 0 && w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor4Sampler, mipC3).w, params[3]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile4HasDisplacement) != 0 && w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandDisplacement4Sampler, mipD4).x, params[4]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile4PBR) != 0 && w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor5Sampler, mipC4).w, params[4]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile5HasDisplacement) != 0 && w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandDisplacement5Sampler, mipD5).x, params[5]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile5PBR) != 0 && w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor6Sampler, mipC5).w, params[5]);
		}

#		undef EMAT_LAND_HMAP
		float total;
		ProcessTerrainHeightWeights(heightBlend, w1, w2, heights, weights, total);
#		if defined(TERRAIN_VARIATION)
		[branch] if (SharedData::terrainVariationSettings.enableTilingFix)
		{
			total *= 1.3;
		}
#		endif
		return total;
	}
#	else
	float GetTerrainHeight(float screenNoise, PS_INPUT input, float2 coords, float mipLevels[6], DisplacementParams params[6], float blendFactor, float4 w1, float2 w2,
#		if defined(TERRAIN_VARIATION)
		StochasticOffsets sharedOffset, float2 dx, float2 dy,
#		endif
		out float weights[6])
	{
		float heightBlend = 1 + blendFactor * HEIGHT_POWER;
		float heights[6] = { 0, 0, 0, 0, 0, 0 };

		float mipTH0 = GetMipLevelForDisplacement(coords, TexLandTHDisp0Sampler);
		float mipC0 = GetMipLevelForDisplacement(coords, TexColorSampler);
		float mipTH1 = GetMipLevelForDisplacement(coords, TexLandTHDisp1Sampler);
		float mipC1 = GetMipLevelForDisplacement(coords, TexLandColor2Sampler);
		float mipTH2 = GetMipLevelForDisplacement(coords, TexLandTHDisp2Sampler);
		float mipC2 = GetMipLevelForDisplacement(coords, TexLandColor3Sampler);
		float mipTH3 = GetMipLevelForDisplacement(coords, TexLandTHDisp3Sampler);
		float mipC3 = GetMipLevelForDisplacement(coords, TexLandColor4Sampler);
		float mipTH4 = GetMipLevelForDisplacement(coords, TexLandTHDisp4Sampler);
		float mipC4 = GetMipLevelForDisplacement(coords, TexLandColor5Sampler);
		float mipTH5 = GetMipLevelForDisplacement(coords, TexLandTHDisp5Sampler);
		float mipC5 = GetMipLevelForDisplacement(coords, TexLandColor6Sampler);

#		if defined(TERRAIN_VARIATION)
#			define EMAT_LAND_HMAP(tex, mip) StochasticEffectParallax(tex, SampTerrainParallaxSampler, coords, mip, sharedOffset, dx, dy)
#		else
#			define EMAT_LAND_HMAP(tex, mip) tex.SampleLevel(SampTerrainParallaxSampler, coords, mip)
#		endif

		if (w1.x > 0.01) {
			[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand0HasDisplacement) != 0)
			{
				heights[0] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandTHDisp0Sampler, mipTH0).x, params[0]);
			}
			else
			{
				heights[0] = ScaleDisplacement(EMAT_LAND_HMAP(TexColorSampler, mipC0).w, params[0]);
			}
		}
		if (w1.y > 0.01) {
			[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand1HasDisplacement) != 0)
			{
				heights[1] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandTHDisp1Sampler, mipTH1).x, params[1]);
			}
			else
			{
				heights[1] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor2Sampler, mipC1).w, params[1]);
			}
		}
		if (w1.z > 0.01) {
			[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand2HasDisplacement) != 0)
			{
				heights[2] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandTHDisp2Sampler, mipTH2).x, params[2]);
			}
			else
			{
				heights[2] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor3Sampler, mipC2).w, params[2]);
			}
		}
		[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand3HasDisplacement) != 0 && w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandTHDisp3Sampler, mipTH3).x, params[3]);
		}
		else if (w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor4Sampler, mipC3).w, params[3]);
		}
		[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand4HasDisplacement) != 0 && w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandTHDisp4Sampler, mipTH4).x, params[4]);
		}
		else if (w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor5Sampler, mipC4).w, params[4]);
		}
		[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand5HasDisplacement) != 0 && w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandTHDisp5Sampler, mipTH5).x, params[5]);
		}
		else if (w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(EMAT_LAND_HMAP(TexLandColor6Sampler, mipC5).w, params[5]);
		}

#		undef EMAT_LAND_HMAP
		float total;
		ProcessTerrainHeightWeights(heightBlend, w1, w2, heights, weights, total);
#		if defined(TERRAIN_VARIATION)
		[branch] if (SharedData::terrainVariationSettings.enableTilingFix)
		{
			total *= 1.3;
		}
#		endif
		return total;
	}
#	endif

#endif

	// One extra height sample stepped toward the sun in tangent UV — cheap contact shading for relief / SSDM.
	float2 ReliefShadowUvStepTowardsLight(float3 Lws, float3 Tw, float3 Bw, float NdotL, float displacementScale)
	{
		float2 Ltb = float2(dot(Lws, Tw), dot(Lws, Bw));
		float2 us = -normalize(Ltb + 1e-5) * (0.0016 + displacementScale * 0.038);
		us *= rcp(max(NdotL, 0.11));
		return us;
	}

	// Landscape UV spans large world patches — use a larger tangent step so the neighbor tap moves ~a texel.
	float2 ReliefShadowUvStepTowardsLightLandscape(float3 Lws, float3 Tw, float3 Bw, float NdotL, float displacementScale)
	{
		float2 Ltb = float2(dot(Lws, Tw), dot(Lws, Bw));
		float2 us = -normalize(Ltb + 1e-5) * (0.0048 + displacementScale * 0.12);
		us *= rcp(max(NdotL, 0.11));
		return us;
	}

	// hToward: height at uv stepped toward the sun in tangent UV. Occlusion only when that tap is higher than center.
	// sunFacing suppresses relief on surfaces facing away from the sun.
	float CheapReliefSelfShadow(float hC, float hToward, float NdotL, float displacementScale, float dhScale)
	{
		float w = saturate(displacementScale * 11.0);
		if (w < 0.045)
			return 1.0;

		float sunFacing = saturate(NdotL * 6.2 - 0.32);
		if (sunFacing < 0.02)
			return 1.0;

		float dh = max(0.0, (hToward - hC) * dhScale);
		float edge = 0.13 + (1.0 - NdotL) * 0.11;
		float occLin = saturate((dh - edge) * (3.8 + 9.0 * (1.0 - NdotL)));
		float x = saturate(occLin * w * sunFacing * 0.42);
		static const float kShadowPow = 1.22;
		static const float kReliefFloor = 0.84;
		return max(pow(saturate(1.0 - x), kShadowPow), kReliefFloor);
	}

#	if defined(LANDSCAPE)
	// Planar landscape UV smears on cliff sides (one axis spans huge world distance). SSDM reprojects in
	// screen space and then pulls wrong neighbors — damp when the surface is steep vs world up and when
	// UV screen derivatives are highly anisotropic.
	// uvMetrics: x = max(ddx,ddy)/min(ddx,ddy), y = max(|ddx|,|ddy|). Meshes pass (0,0).
	// When y is tiny (distance / coarse footprint), x collapses toward 1 and must not lift trust — blend to
	// slope-only trust so relief / SSDM do not ramp up incorrectly far from the camera.
	float LandscapeSsdmTrust(float3 Nw, float2 uvMetrics)
	{
		float uvDerivativeAniso = uvMetrics.x;
		float uvDerivMax = max(uvMetrics.y, 0.0);

		float upA = saturate(abs(normalize(Nw).z));
		float slopeFade = smoothstep(0.028, 0.46, upA);
		// Screen UV derivatives shrink with distance → aniso ratio collapses toward 1 and would read as
		// "unstretched" and lift trust. When |ddx/ddy| is tiny, blend toward a conservative high aniso so
		// stretchFade does not incorrectly relax relief / SSDM farther from the camera.
		float derivWeight = saturate(uvDerivMax * 14000.0);
		float anisoResolved = lerp(max(uvDerivativeAniso, 28.0), uvDerivativeAniso, smoothstep(0.04, 1.0, derivWeight));
		float stretchFade = 1.0;
		if (anisoResolved > 3.5)
			stretchFade = saturate(1.0 - smoothstep(3.5, 88.0, anisoResolved) * 0.94);
		return saturate(slopeFade * stretchFade);
	}
#	endif

	// POM-style tangent step (Vt.xy / Vt.z) then world-space offset and projection — same relief as parallax,
	// with a slope-aware denominator so grazing views do not explode like 1/|Vt.z|.
	// Callers pass surface → camera (Lighting `viewDirection`, or `refractedViewDirection` for coated PBR).
	// The tangent step uses the ray into the surface (camera → surface), i.e. the negated view vector.
	// landscapeUvMetrics: LANDSCAPE only — float2(aniso, maxDeriv); meshes pass (0,0). Use zw derivatives when TV tiling fix matches stochastic UV.
	float2 ComputeDisplacementVector(float3 viewPosVS, float3 viewDirWorld, float3 tbnTr0, float3 tbnTr1, float3 tbnTr2,
		float height, float displacementScale, uint eyeIndex, float2 landscapeUvMetrics)
	{
		float hRaw = clamp(height, -0.75, 0.75);
		// Soft squash of large |h| (stacked terrain / high material height scale) — reduces spike-driven SSDM noise.
		// Lighter squash keeps SSDM height closer to the authored map (triplanar / heavy squash read as muddy swirls).
#	if defined(LANDSCAPE) && defined(EMAT)
		// Keep height shape stable vs multiplier; noise is handled by mip nudge + screen hop, not extra squash
		// that fought amplitude and made the slider feel like UV drift instead of depth.
		float hSquashK = 0.14 + 0.10 * saturate((max(displacementScale, 1e-5) / 0.05 - 1.0) * 0.45);
		float h = hRaw * rcp(1.0 + abs(hRaw) * hSquashK);
#	else
		float h = hRaw * rcp(1.0 + abs(hRaw) * 0.14);
#	endif

		float3 Tw = normalize(tbnTr0);
		float3 Bw = normalize(tbnTr1);
		float3 Nw = normalize(tbnTr2);
		float3 Vw = -normalize(viewDirWorld);

		float3 Vt;
		Vt.x = dot(Vw, Tw);
		Vt.y = dot(Vw, Bw);
		Vt.z = dot(Vw, Nw);

		// Oblique / relaxed denominator: zn ~ |z| + k*|xy| caps tangent parallax rate at grazing
		// (pure max(|z|,eps) makes |xy|/eps huge and warps SSDM).
		float zn = max(abs(Vt.z), 0.02) + 0.58 * length(Vt.xy);
		float2 parallaxDir = Vt.xy / zn;
		float pdLen = length(parallaxDir);
		if (pdLen > 4.5)
			parallaxDir *= 4.5 / pdLen;

		static const float kLegacyNormalPush = 32.0;
		static const float kDefaultDisplacementScale = 0.05;
		static const float kTangentParallaxAmpScale = 0.22;
		float amp = h * displacementScale * (kLegacyNormalPush / kDefaultDisplacementScale) * kTangentParallaxAmpScale;

#	if defined(LANDSCAPE)
		float trust = LandscapeSsdmTrust(Nw, landscapeUvMetrics);
		amp *= trust;
#	endif

		// World tangent step (POM), then rotate to view and project — matches camera path better than
		// adding Tvs/Bvs directly in view when TBN is skewed or non-orthonormal.
		float3 worldOff = -(Tw * parallaxDir.x + Bw * parallaxDir.y) * amp;
		float3 offsetVS = FrameBuffer::WorldToView(worldOff, false, eyeIndex);

		float2 uv0 = FrameBuffer::ViewToUV(viewPosVS, true, eyeIndex);
		float2 uv1 = FrameBuffer::ViewToUV(viewPosVS + offsetVS, true, eyeIndex);
		float2 duv = uv1 - uv0;

		// Tighter screen pull when displacement is cranked — reduces incoherent neighbor blends that read as swirl.
#	if defined(EMAT)
		// `displacementScale` argument is effective authored magnitude (see Lighting kEmatAuthoredDispRef path).
		float ds = max(displacementScale, 1e-5);
		float maxScreenHop = lerp(0.038, 0.021, saturate((ds - 0.05) * 14.0));
#	else
		float maxScreenHop = 0.038;
#	endif
#	if defined(LANDSCAPE)
#		if defined(EMAT)
		// Landscape SSDM reprojects deferred albedo from shifted pixels; extra cap vs multiplier avoids vertical streaking.
		float dsNorm = ds / 0.05;
		maxScreenHop *= rcp(1.0 + 0.62 * max(0.0, dsNorm - 1.0));
#		endif
		maxScreenHop *= lerp(0.40, 1.0, trust);
#	endif
		float len = length(duv);
		if (len > maxScreenHop)
			duv *= maxScreenHop / len;

		return duv;
	}
}
