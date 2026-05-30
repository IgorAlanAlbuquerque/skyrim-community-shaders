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

	void UpdateSSDMCB();
	void DrawSSDM();

	// Returns the final virtual depth SRV for this frame (after temporal + blur when enabled),
	// or nullptr when the feature is disabled or resources are not ready.
	// Consumed by SSAO/SSGI in Task 7.
	ID3D11ShaderResourceView* GetVirtualDepthSRV() const;

	// Returns true when a camera cut or teleport is detected (large positional jump).
	// Used to clear temporal history and prevent ghosting.
	bool CameraJumpDetected();

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
		float4x4 PrevInvViewMat[2];   // 128 bytes — prev frame cam-to-world
		float4x4 CurrInvViewMat[2];   // 128 bytes — current frame cam-to-world
		float4x4 PrevViewProjMat[2];  // 128 bytes — prev frame view×proj (reprojection)
		float2   NDCToViewMul[2];     // 16 bytes
		float2   NDCToViewAdd[2];     // 16 bytes
		float2   TexDim;              // 8 bytes
		float2   RcpTexDim;           // 8 bytes
		float2   FrameDim;            // 8 bytes
		float2   RcpFrameDim;         // 8 bytes → 448
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
		float    BlurDepthSigma;   // → 492
		float    pad[5];           // pad to 512 bytes
	};
	STATIC_ASSERT_ALIGNAS_16(SSDMCB);
	eastl::unique_ptr<ConstantBuffer> ssdmCB;

	// Depth hierarchy: 5-mip conservative (max) pyramid at half resolution.
	// Mip 0 = half-res, mip 4 = 1/32 of full res.  Used by the ray-march pass.
	eastl::unique_ptr<Texture2D>              texDepthHierarchy    = nullptr;
	winrt::com_ptr<ID3D11UnorderedAccessView> uavDepthHierarchy[5] = { nullptr };
	winrt::com_ptr<ID3D11ComputeShader>       csPrefilterDepth     = nullptr;

	// Ray-march output (R32_FLOAT virtual depth), ping-pong via outputIdx.
	eastl::unique_ptr<Texture2D> texRefinedDepth[2] = { nullptr };
	winrt::com_ptr<ID3D11ComputeShader> csDisplace   = nullptr;

	// Temporal history (R32_FLOAT), ping-pong matching outputIdx.
	// Temporal reads history from [1-outputIdx], writes to [outputIdx].
	eastl::unique_ptr<Texture2D> texRefinedDepthHistory[2] = { nullptr };
	winrt::com_ptr<ID3D11ComputeShader> csTemporal           = nullptr;

	// Per-pixel frame accumulation counter (R8_UINT, [0..MaxAccumFrames]).
	eastl::unique_ptr<Texture2D> texAccumCount = nullptr;

	// Blur output reuses texRefinedDepth[outputIdx] after displace is consumed.
	winrt::com_ptr<ID3D11ComputeShader> csBlur = nullptr;

	// Points to the actual final SRV for this frame (set before outputIdx flip).
	// GetVirtualDepthSRV() returns this directly.
	ID3D11ShaderResourceView* latestOutputSRV = nullptr;

	// Camera position from last frame, used for jump detection.
	float3 prevCameraPos      = {};
	bool   firstFrameTemporal = true;

	winrt::com_ptr<ID3D11SamplerState> samplerPointClamp  = nullptr;
	winrt::com_ptr<ID3D11SamplerState> samplerLinearClamp = nullptr;
};
