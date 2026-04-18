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
		float m = max(floor(mipLevel + 0.5), 0);
		// SSDM height is not filtered like diffuse: very high mips read as smeared / swimming relief.
		return min(m, 4);
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

		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile0HasDisplacement) != 0 && w1.x > 0.01)
		{
			heights[0] = ScaleDisplacement(TexLandDisplacement0Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipD0).x, params[0]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile0PBR) != 0 && w1.x > 0.01)
		{
			heights[0] = ScaleDisplacement(TexColorSampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC0).w, params[0]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile1HasDisplacement) != 0 && w1.y > 0.01)
		{
			heights[1] = ScaleDisplacement(TexLandDisplacement1Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipD1).x, params[1]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile1PBR) != 0 && w1.y > 0.01)
		{
			heights[1] = ScaleDisplacement(TexLandColor2Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC1).w, params[1]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile2HasDisplacement) != 0 && w1.z > 0.01)
		{
			heights[2] = ScaleDisplacement(TexLandDisplacement2Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipD2).x, params[2]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile2PBR) != 0 && w1.z > 0.01)
		{
			heights[2] = ScaleDisplacement(TexLandColor3Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC2).w, params[2]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile3HasDisplacement) != 0 && w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(TexLandDisplacement3Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipD3).x, params[3]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile3PBR) != 0 && w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(TexLandColor4Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC3).w, params[3]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile4HasDisplacement) != 0 && w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(TexLandDisplacement4Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipD4).x, params[4]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile4PBR) != 0 && w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(TexLandColor5Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC4).w, params[4]);
		}
		[branch] if ((PBRFlags & PBR::TerrainFlags::LandTile5HasDisplacement) != 0 && w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(TexLandDisplacement5Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipD5).x, params[5]);
		}
		else [branch] if ((PBRFlags & PBR::TerrainFlags::LandTile5PBR) != 0 && w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(TexLandColor6Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC5).w, params[5]);
		}

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

		if (w1.x > 0.01) {
			[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand0HasDisplacement) != 0)
			{
				heights[0] = ScaleDisplacement(TexLandTHDisp0Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipTH0).x, params[0]);
			}
			else
			{
				heights[0] = ScaleDisplacement(TexColorSampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC0).w, params[0]);
			}
		}
		if (w1.y > 0.01) {
			[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand1HasDisplacement) != 0)
			{
				heights[1] = ScaleDisplacement(TexLandTHDisp1Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipTH1).x, params[1]);
			}
			else
			{
				heights[1] = ScaleDisplacement(TexLandColor2Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC1).w, params[1]);
			}
		}
		if (w1.z > 0.01) {
			[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand2HasDisplacement) != 0)
			{
				heights[2] = ScaleDisplacement(TexLandTHDisp2Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipTH2).x, params[2]);
			}
			else
			{
				heights[2] = ScaleDisplacement(TexLandColor3Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC2).w, params[2]);
			}
		}
		[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand3HasDisplacement) != 0 && w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(TexLandTHDisp3Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipTH3).x, params[3]);
		}
		else if (w1.w > 0.01)
		{
			heights[3] = ScaleDisplacement(TexLandColor4Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC3).w, params[3]);
		}
		[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand4HasDisplacement) != 0 && w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(TexLandTHDisp4Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipTH4).x, params[4]);
		}
		else if (w2.x > 0.01)
		{
			heights[4] = ScaleDisplacement(TexLandColor5Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC4).w, params[4]);
		}
		[branch] if ((Permutation::ExtraFeatureDescriptor & Permutation::ExtraFeatureFlags::THLand5HasDisplacement) != 0 && w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(TexLandTHDisp5Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipTH5).x, params[5]);
		}
		else if (w2.y > 0.01)
		{
			heights[5] = ScaleDisplacement(TexLandColor6Sampler.SampleLevel(SampTerrainParallaxSampler, coords, mipC5).w, params[5]);
		}

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

	// First-order tangent-space parallax mapped through the projection, instead of pushing along
	// view-space N with a magic constant (that ignored displacementScale and blew up at grazing).
	// viewDirWorld: camera → surface (`normalize(WorldPosition)`), same as water parallax input.
	// Do not apply Water.hlsl's parallaxDir.y world flip here — that is for world-xy / flow UV, not tangent Vt.
	float2 ComputeDisplacementVector(float3 viewPosVS, float3 viewDirWorld, float3 tbnTr0, float3 tbnTr1, float3 tbnTr2,
		float height, float displacementScale, uint eyeIndex)
	{
		float h = clamp(height, -0.75, 0.75);

		float3 Vt;
		Vt.x = dot(viewDirWorld, tbnTr0);
		Vt.y = dot(viewDirWorld, tbnTr1);
		Vt.z = dot(viewDirWorld, tbnTr2);

		float zn = max(abs(Vt.z), 0.18);
		float2 parallaxDir = Vt.xy / zn;
		float pdLen = length(parallaxDir);
		if (pdLen > 6.0)
			parallaxDir *= 6.0 / pdLen;

		float3 Tvs = normalize(FrameBuffer::WorldToView(tbnTr0, false, eyeIndex));
		float3 Bvs = normalize(FrameBuffer::WorldToView(tbnTr1, false, eyeIndex));

		static const float kLegacyNormalPush = 32.0;
		static const float kDefaultDisplacementScale = 0.05;
		// Legacy 32×push was view-N only; tangent→ViewToUV needs much less or gbuffer pulls like radial zoom.
		static const float kTangentParallaxAmpScale = 0.22;
		float amp = h * displacementScale * (kLegacyNormalPush / kDefaultDisplacementScale) * kTangentParallaxAmpScale;
		float3 offsetVS = -(Tvs * parallaxDir.x + Bvs * parallaxDir.y) * amp;

		float2 uv0 = FrameBuffer::ViewToUV(viewPosVS, true, eyeIndex);
		float2 uv1 = FrameBuffer::ViewToUV(viewPosVS + offsetVS, true, eyeIndex);
		float2 duv = uv1 - uv0;

		const float maxScreenHop = 0.028;
		float len = length(duv);
		if (len > maxScreenHop)
			duv *= maxScreenHop / len;

		return duv;
	}
}
