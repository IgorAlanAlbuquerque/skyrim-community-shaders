#pragma once

#include "Buffer.h"

struct ScreenSpaceDisplacementMapping : Feature
{
public:
	bool inline SupportsVR() override { return true; }

	virtual inline std::string GetName() override { return "Screen Space Displacement Mapping"; }
	virtual inline std::string GetShortName() override { return "ScreenSpaceDisplacementMapping"; }
	virtual inline std::string_view GetShaderDefineName() override { return "SCREEN_SPACE_DISPLACEMENT_MAPPING"; }
	virtual std::string_view GetCategory() const override { return FeatureCategories::kMaterials; }

	bool HasShaderDefine(RE::BSShader::Type shaderType) override;

	virtual std::pair<std::string, std::vector<std::string>> GetFeatureSummary() override;

	virtual void RestoreDefaultSettings() override;
	virtual void DrawSettings() override;
	virtual void LoadSettings(json& o_json) override;
	virtual void SaveSettings(json& o_json) override;

	virtual void SetupResources() override;
	virtual void ClearShaderCache() override;

	void DrawSSDM();

	// Returns the refined UV offset SRV produced by ray marching, or nullptr when
	// this feature is disabled or not yet computed. Deferred.cpp checks this first;
	// if null it falls back to ExtendedMaterials::GetSSDMOffsetSRV() (UV-redirect).
	ID3D11ShaderResourceView* GetOffsetSRV() const;

	// D3D11 RT slot where Lighting.hlsl writes the SSDMDisplacement output (SV_Target7).
	// RG = screen-space UV delta, B = raw parallax height [0,1], A = reserved.
	static constexpr uint32_t kHeightGBufferRTVSlot = 7;

	/////////////////////////////////////////////////////////////////////////

	bool recompileFlag = false;
	uint outputIdx = 0;

	struct Settings
	{
		bool  Enabled                     = true;
		bool  EnableTemporalStabilization = true;
		bool  EnableBlur                  = true;
		uint  NumRaymarchSteps            = 8;
		uint  NumBinarySearchSteps        = 4;
		float DisplacementScale           = 1.0f;
		float MaxDisplacementDist         = 0.5f;
		uint  ResolutionMode              = 1;
		float FadeAngle                   = 70.0f;
		float MinBlendAlpha               = 0.08f;
		uint  MaxAccumFrames              = 32;
		uint  BlurRadius                  = 1;
		float BlurDepthSigma              = 0.1f;
	} settings;

	struct alignas(16) SSDMCB
	{
		float4x4 PrevInvViewMat[2];   // 128 bytes
		float2   NDCToViewMul[2];     // 16 bytes
		float2   NDCToViewAdd[2];     // 16 bytes
		float2   TexDim;              // 8 bytes
		float2   RcpTexDim;           // 8 bytes
		float2   FrameDim;            // 8 bytes
		float2   RcpFrameDim;         // 8 bytes → running total: 192
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
		float    BlurDepthSigma;   // running total: 236
		float    pad[5];           // pad to 256 bytes
	};
	STATIC_ASSERT_ALIGNAS_16(SSDMCB);
	eastl::unique_ptr<ConstantBuffer> ssdmCB;

	eastl::unique_ptr<Texture2D> texRefinedDepth[2] = { nullptr };

	winrt::com_ptr<ID3D11ComputeShader> csDisplace = nullptr;
};
