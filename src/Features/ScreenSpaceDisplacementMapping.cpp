#include "ScreenSpaceDisplacementMapping.h"

#include "Deferred.h"
#include "Features/ExtendedMaterials.h"
#include "State.h"
#include "Util.h"

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT(
	ScreenSpaceDisplacementMapping::Settings,
	Enabled,
	EnableTemporalStabilization,
	EnableBlur,
	NumRaymarchSteps,
	NumBinarySearchSteps,
	DisplacementScale,
	MaxDisplacementDist,
	ResolutionMode,
	FadeAngle,
	MinBlendAlpha,
	MaxAccumFrames,
	BlurRadius,
	BlurDepthSigma)

////////////////////////////////////////////////////////////////////////////////////

bool ScreenSpaceDisplacementMapping::HasShaderDefine(RE::BSShader::Type)
{
	// No game shader types currently need the SCREEN_SPACE_DISPLACEMENT_MAPPING define.
	// Ray-march compute shaders (TASK-SSDM-005) are compiled directly via Util::CompileShader
	// and receive their defines there, not through the ShaderCache game-shader path.
	return false;
}

std::pair<std::string, std::vector<std::string>> ScreenSpaceDisplacementMapping::GetFeatureSummary()
{
	return std::make_pair(
		"Screen Space Displacement Mapping refines apparent surface geometry by raymarching "
		"height data in screen-space, improving SSAO, SSGI and SSR integration for parallax materials.",
		std::vector<std::string>{
			"Screen-space raymarching against parallax height fields",
			"Temporal accumulation for stable results",
			"Improved SSAO/SSGI depth accuracy on textured surfaces",
			"Fade at grazing angles to minimize artifacts" });
}

void ScreenSpaceDisplacementMapping::RestoreDefaultSettings()
{
	settings = {};
	recompileFlag = true;
}

void ScreenSpaceDisplacementMapping::DrawSettings()
{
	ImGui::Checkbox("Enabled", &settings.Enabled);
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text("Enable Screen Space Displacement Mapping. Refines apparent depth of parallax surfaces for improved SSAO/SSGI interaction.");
}

void ScreenSpaceDisplacementMapping::LoadSettings(json& o_json)
{
	settings = o_json;
}

void ScreenSpaceDisplacementMapping::SaveSettings(json& o_json)
{
	o_json = settings;
}

void ScreenSpaceDisplacementMapping::SetupResources()
{
	auto device   = globals::d3d::device;
	auto renderer = globals::game::renderer;

	auto& mainRT = renderer->GetRuntimeData().renderTargets[RE::RENDER_TARGETS::kMAIN];
	D3D11_TEXTURE2D_DESC mainDesc{};
	mainRT.texture->GetDesc(&mainDesc);

	const uint halfW = std::max(1u, mainDesc.Width  / 2);
	const uint halfH = std::max(1u, mainDesc.Height / 2);

	// ---- Depth hierarchy (5-mip conservative pyramid, half-res base) --------
	{
		D3D11_TEXTURE2D_DESC texDesc{
			.Width     = halfW,
			.Height    = halfH,
			.MipLevels = 5,
			.ArraySize = 1,
			.Format    = DXGI_FORMAT_R32_FLOAT,
			.SampleDesc = { .Count = 1, .Quality = 0 },
			.Usage      = D3D11_USAGE_DEFAULT,
			.BindFlags  = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS,
		};
		texDepthHierarchy = eastl::make_unique<Texture2D>(texDesc, "SSDM::DepthHierarchy");
		texDepthHierarchy->CreateSRV(D3D11_SHADER_RESOURCE_VIEW_DESC{
			.Format        = DXGI_FORMAT_R32_FLOAT,
			.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
			.Texture2D     = { .MostDetailedMip = 0, .MipLevels = 5 } });

		for (uint i = 0; i < 5; ++i) {
			D3D11_UNORDERED_ACCESS_VIEW_DESC uavDesc{
				.Format        = DXGI_FORMAT_R32_FLOAT,
				.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
				.Texture2D     = { .MipSlice = i }
			};
			DX::ThrowIfFailed(device->CreateUnorderedAccessView(
				texDepthHierarchy->resource.get(), &uavDesc, uavDepthHierarchy[i].put()));
			Util::SetResourceName(uavDepthHierarchy[i].get(), "SSDM::DepthHierarchy UAV mip%u", i);
		}
	}

	// ---- Samplers -----------------------------------------------------------
	{
		D3D11_SAMPLER_DESC desc{
			.Filter         = D3D11_FILTER_MIN_MAG_MIP_POINT,
			.AddressU       = D3D11_TEXTURE_ADDRESS_CLAMP,
			.AddressV       = D3D11_TEXTURE_ADDRESS_CLAMP,
			.AddressW       = D3D11_TEXTURE_ADDRESS_CLAMP,
			.MaxAnisotropy  = 1,
			.MinLOD         = 0,
			.MaxLOD         = D3D11_FLOAT32_MAX,
		};
		DX::ThrowIfFailed(device->CreateSamplerState(&desc, samplerPointClamp.put()));
		Util::SetResourceName(samplerPointClamp.get(), "SSDM::PointClampSampler");

		desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
		DX::ThrowIfFailed(device->CreateSamplerState(&desc, samplerLinearClamp.put()));
		Util::SetResourceName(samplerLinearClamp.get(), "SSDM::LinearClampSampler");
	}

	// ---- Virtual depth output (ping-pong) ------------------------------------
	// Stores view-space linear depth of the apparent displaced surface.
	// R32_FLOAT preserves depth precision needed for SSAO/SSGI integration (Task 7).
	// Smaller value than original → surface appears raised (closer to camera).
	{
		D3D11_TEXTURE2D_DESC texDesc{
			.Width      = mainDesc.Width,
			.Height     = mainDesc.Height,
			.MipLevels  = 1,
			.ArraySize  = 1,
			.Format     = DXGI_FORMAT_R32_FLOAT,
			.SampleDesc = { .Count = 1, .Quality = 0 },
			.Usage      = D3D11_USAGE_DEFAULT,
			.BindFlags  = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS,
		};
		for (int i = 0; i < 2; ++i) {
			auto name       = fmt::format("SSDM::RefinedDepth{}", i);
			texRefinedDepth[i] = eastl::make_unique<Texture2D>(texDesc, name.c_str());
			texRefinedDepth[i]->CreateSRV({
				.Format        = DXGI_FORMAT_R32_FLOAT,
				.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
				.Texture2D     = { .MostDetailedMip = 0, .MipLevels = 1 } });
			texRefinedDepth[i]->CreateUAV({
				.Format        = DXGI_FORMAT_R32_FLOAT,
				.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
				.Texture2D     = { .MipSlice = 0 } });
		}
	}

	// ---- Constant buffer ----------------------------------------------------
	ssdmCB = eastl::make_unique<ConstantBuffer>(ConstantBufferDesc<SSDMCB>());

	ClearShaderCache();
}

void ScreenSpaceDisplacementMapping::ClearShaderCache()
{
	csPrefilterDepth = nullptr;
	csDisplace       = nullptr;
	recompileFlag    = true;

	const auto shaderDir = std::filesystem::path("Data\\Shaders\\ScreenSpaceDisplacementMapping");

	if (auto* raw = reinterpret_cast<ID3D11ComputeShader*>(
			Util::CompileShader((shaderDir / "prefilterDepth.cs.hlsl").c_str(), {}, "cs_5_0")))
		csPrefilterDepth.attach(raw);

	if (auto* raw = reinterpret_cast<ID3D11ComputeShader*>(
			Util::CompileShader((shaderDir / "displace.cs.hlsl").c_str(), {}, "cs_5_0")))
		csDisplace.attach(raw);
}

void ScreenSpaceDisplacementMapping::UpdateSSDMCB()
{
	static float4x4 prevInvView[2] = {};

	SSDMCB data{};
	const int numEyes = 1 + REL::Module::IsVR();
	for (int eyeIndex = 0; eyeIndex < numEyes; ++eyeIndex) {
		auto eye = Util::GetCameraData(eyeIndex);

		data.PrevInvViewMat[eyeIndex] = prevInvView[eyeIndex];
		data.NDCToViewMul[eyeIndex]   = { 2.0f / eye.projMat(0, 0), -2.0f / eye.projMat(1, 1) };
		data.NDCToViewAdd[eyeIndex]   = { -1.0f / eye.projMat(0, 0), 1.0f / eye.projMat(1, 1) };
		if (REL::Module::IsVR())
			data.NDCToViewMul[eyeIndex].x *= 2.0f;

		prevInvView[eyeIndex] = eye.viewMat.Invert();
	}

	const float2 texDim   = { (float)texDepthHierarchy->desc.Width,
		                       (float)texDepthHierarchy->desc.Height };
	const float2 frameDim = Util::ConvertToDynamic(
		{ (float)texRefinedDepth[0]->desc.Width, (float)texRefinedDepth[0]->desc.Height });

	data.TexDim              = texDim;
	data.RcpTexDim           = float2(1.0f) / texDim;
	data.FrameDim            = frameDim;
	data.RcpFrameDim         = float2(1.0f) / frameDim;
	data.FrameIndex          = globals::state->frameCount;
	data.DisplacementScale   = settings.DisplacementScale;
	data.MaxDisplacementDist = settings.MaxDisplacementDist;
	data.FadeAngleCos        = std::cosf(settings.FadeAngle * (3.14159265f / 180.0f));
	data.NumRaymarchSteps    = settings.NumRaymarchSteps;
	data.NumBinarySearchSteps = settings.NumBinarySearchSteps;
	data.ResolutionMode      = settings.ResolutionMode;
	data.MinBlendAlpha       = settings.MinBlendAlpha;
	data.MaxAccumFrames      = settings.MaxAccumFrames;
	data.BlurRadius          = settings.BlurRadius;
	data.BlurDepthSigma      = settings.BlurDepthSigma;

	ssdmCB->Update(data);
}

void ScreenSpaceDisplacementMapping::DrawSSDM()
{
	if (!loaded || !settings.Enabled)
		return;
	if (!csPrefilterDepth || !texDepthHierarchy)
		return;

	ZoneScoped;

	auto context = globals::d3d::context;

	// Update constant buffer with current frame data.
	UpdateSSDMCB();

	// Bind shared state used by both passes.
	auto* cb       = ssdmCB->CB();
	auto* sharedCB = globals::state->sharedDataCB->CB();
	context->CSSetConstantBuffers(1, 1, &cb);
	context->CSSetConstantBuffers(5, 1, &sharedCB);

	ID3D11SamplerState* samplers[] = { samplerPointClamp.get(), samplerLinearClamp.get() };
	context->CSSetSamplers(0, 2, samplers);

	// --- Prefilter depth pyramid --------------------------------------------
	{
		TracyD3D11Zone(globals::state->tracyCtx, "SSDM - Prefilter Depth");

		const uint halfW = texDepthHierarchy->desc.Width;
		const uint halfH = texDepthHierarchy->desc.Height;

		ID3D11ShaderResourceView* srvs[] = { Util::GetCurrentSceneDepthSRV() };
		context->CSSetShaderResources(0, 1, srvs);

		ID3D11UnorderedAccessView* uavs[5];
		for (int i = 0; i < 5; ++i)
			uavs[i] = uavDepthHierarchy[i].get();
		context->CSSetUnorderedAccessViews(0, 5, uavs, nullptr);

		context->CSSetShader(csPrefilterDepth.get(), nullptr, 0);
		// Each thread covers a 2×2 mip-0 block → dispatch covers mip-1 dimensions.
		context->Dispatch((halfW / 2 + 7) / 8, (halfH / 2 + 7) / 8, 1);

		ID3D11ShaderResourceView*  nullSrv[1] = { nullptr };
		ID3D11UnorderedAccessView* nullUav[5] = {};
		context->CSSetShaderResources(0, 1, nullSrv);
		context->CSSetUnorderedAccessViews(0, 5, nullUav, nullptr);
	}

	// --- Ray-march displace pass -------------------------------------------
	if (csDisplace && texRefinedDepth[outputIdx]) {
		TracyD3D11Zone(globals::state->tracyCtx, "SSDM - Displace");

		auto  renderer = globals::game::renderer;
		auto& em       = globals::features::extendedMaterials;

		ID3D11ShaderResourceView* srvs[] = {
			Util::GetCurrentSceneDepthSRV(),                                        // t0 raw NDC depth
			renderer->GetRuntimeData().renderTargets[NORMALROUGHNESS].SRV,          // t1 normals
			em.loaded ? em.GetHeightGBufferSRV() : nullptr,                         // t2 parallax height
			texDepthHierarchy->srv.get(),                                           // t3 depth pyramid
		};
		context->CSSetShaderResources(0, ARRAYSIZE(srvs), srvs);

		ID3D11UnorderedAccessView* uav = texRefinedDepth[outputIdx]->uav.get();
		context->CSSetUnorderedAccessViews(0, 1, &uav, nullptr);

		context->CSSetShader(csDisplace.get(), nullptr, 0);
		const uint w = texRefinedDepth[outputIdx]->desc.Width;
		const uint h = texRefinedDepth[outputIdx]->desc.Height;
		context->Dispatch((w + 15) / 16, (h + 15) / 16, 1);

		ID3D11ShaderResourceView*  nullSrvs[4] = {};
		ID3D11UnorderedAccessView* nullUav      = nullptr;
		context->CSSetShaderResources(0, ARRAYSIZE(nullSrvs), nullSrvs);
		context->CSSetUnorderedAccessViews(0, 1, &nullUav, nullptr);
	}

	// Unbind shared constant buffers and samplers.
	ID3D11Buffer*       nullCB[1]   = { nullptr };
	ID3D11SamplerState* nullSamp[2] = {};
	context->CSSetConstantBuffers(1, 1, nullCB);
	context->CSSetConstantBuffers(5, 1, nullCB);
	context->CSSetSamplers(0, 2, nullSamp);
}

ID3D11ShaderResourceView* ScreenSpaceDisplacementMapping::GetVirtualDepthSRV() const
{
	if (!loaded || !settings.Enabled)
		return nullptr;
	if (!csDisplace || !texRefinedDepth[outputIdx])
		return nullptr;
	return texRefinedDepth[outputIdx]->srv.get();
}
