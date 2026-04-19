#pragma once

#include <cstdint>

#include "Buffer.h"

struct ExtendedMaterials : Feature
{
	virtual inline std::string GetName() override { return "Extended Materials"; }
	virtual inline std::string GetShortName() override { return "ExtendedMaterials"; }
	virtual inline std::string_view GetShaderDefineName() override { return "EXTENDED_MATERIALS"; }
	virtual std::string_view GetCategory() const override { return FeatureCategories::kMaterials; }

	virtual std::pair<std::string, std::vector<std::string>> GetFeatureSummary() override
	{
		return {
			"Extended Materials adds advanced material effects including screen-space displacement mapping and complex material blending.\n"
			"This feature enhances surface detail and depth perception for more realistic textures.",
			{ "Screen-space displacement mapping (SSDM)",
				"Complex material blending",
				"Terrain heightmap support",
				"Height-based texture blending" }
		};
	}

	bool HasShaderDefine(RE::BSShader::Type shaderType) override;

	struct alignas(16) Settings
	{
		uint EnableComplexMaterial = 1;

		uint EnableParallax = 1;
		uint EnableTerrain = 0;
		uint EnableHeightBlending = 1;

		// Multiplier on material-authored displacement (1 = default). Legacy saves used ~0.05 as absolute scale.
		float DisplacementScale = 1.0f;
		float pad[3];
	};
	STATIC_ASSERT_ALIGNAS_16(Settings);

	Settings settings;

	virtual void DataLoaded() override;

	virtual void DrawSettings() override;

	virtual void LoadSettings(json& o_json) override;
	virtual void SaveSettings(json& o_json) override;

	virtual void RestoreDefaultSettings() override;

	virtual void SetupResources() override;
	virtual void ClearShaderCache() override;

	void DrawSSDM();
	void RegisterDisplacementRT();

	virtual bool SupportsVR() override { return true; };
	virtual bool IsCore() const override { return true; };

	// SSDM: lighting writes duv in RG of texDisplacement mip0; pyramid + solve write absolute fetch UV to texSSDMLevel[0].
	static constexpr int SSDM_MIP_LEVELS = 4;

	eastl::unique_ptr<Texture2D> texDisplacement;
	winrt::com_ptr<ID3D11RenderTargetView> rtvDisplacement;
	winrt::com_ptr<ID3D11UnorderedAccessView> uavDisplacement[SSDM_MIP_LEVELS];

	eastl::unique_ptr<Texture2D> texSSDMLevel[SSDM_MIP_LEVELS];

	ID3D11ShaderResourceView* GetSSDMOffsetSRV() const;
	void ClearDisplacementTexture();

private:
	void CompileSSDMComputeShadersIfNeeded();

	struct alignas(16) SSDMBuildPyramidCB {
		std::int32_t srcMip;
		std::int32_t pad[3];
	};
	STATIC_ASSERT_ALIGNAS_16(SSDMBuildPyramidCB);

	struct alignas(16) SSDMSolveCB {
		float fullWidth;
		float fullHeight;
		float rcpFullWidth;
		float rcpFullHeight;
		std::int32_t numMips;
		std::int32_t numIters;
		float maxStepUv;
		float damping;
	};
	STATIC_ASSERT_ALIGNAS_16(SSDMSolveCB);
	static_assert(sizeof(SSDMBuildPyramidCB) == 16);
	static_assert(sizeof(SSDMSolveCB) == 32);

	winrt::com_ptr<ID3D11ComputeShader> ssdmBuildPyramidCS;
	winrt::com_ptr<ID3D11ComputeShader> ssdmSolveCS;
	eastl::unique_ptr<ConstantBuffer> cbufSSDMBuild;
	eastl::unique_ptr<ConstantBuffer> cbufSSDMSolve;
};
