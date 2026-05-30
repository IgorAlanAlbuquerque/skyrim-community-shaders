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
	ImGui::TextDisabled("Configure via Extended Materials \xe2\x86\x92 Screen Space Displacement.");
}

void ScreenSpaceDisplacementMapping::DrawInlineSettings()
{
	if (!loaded)
		return;

	ImGui::Spacing();
	ImGui::Checkbox("Enable Raymarching Depth Refinement", &settings.Enabled);
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text(
			"Refines apparent surface depth via screen-space raymarching for improved\n"
			"SSAO and SSGI integration. Requires Enable Displacement.");

	if (!settings.Enabled)
		return;

	ImGui::Indent();

	// ---- Raymarching --------------------------------------------------------
	ImGui::SeparatorText("Raymarching");

	ImGui::SliderInt("Steps##ssdm", (int*)&settings.NumRaymarchSteps, 4, 32);
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text("Number of ray-march steps. Higher = more accurate but more expensive.");
	if (settings.NumRaymarchSteps > 16)
		ImGui::TextColored({ 1.f, 0.7f, 0.f, 1.f },
			"[!] High step count — consider Half resolution to compensate.");

	ImGui::SliderInt("Binary Refinement##ssdm", (int*)&settings.NumBinarySearchSteps, 0, 8);
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text("Sub-step binary search for sharper contact edges.");

	ImGui::SliderFloat("Scale##ssdm", &settings.DisplacementScale, 0.1f, 3.0f, "%.2f");
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text("Displacement intensity multiplier.");

	ImGui::SliderFloat("Max Distance##ssdm", &settings.MaxDisplacementDist, 0.05f, 2.0f, "%.2f m");
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text("Maximum ray-march distance in view-space units.");

	// ---- Quality ------------------------------------------------------------
	ImGui::SeparatorText("Quality");

	{
		static const char* resModes[] = { "Full", "Half (Recommended)", "Quarter" };
		int mode = (int)settings.ResolutionMode;
		if (ImGui::Combo("Resolution##ssdm", &mode, resModes, IM_ARRAYSIZE(resModes))) {
			settings.ResolutionMode = (uint)mode;
			recompileFlag = true;
		}
		if (auto _tt = Util::HoverTooltipWrapper())
			ImGui::Text("Resolution for the ray-march pass. Half is recommended for most GPUs.");
	}

	ImGui::SliderFloat("Fade Angle##ssdm", &settings.FadeAngle, 30.0f, 85.0f, "%.1f deg");
	if (auto _tt = Util::HoverTooltipWrapper())
		ImGui::Text("Angle at which the effect fades out to avoid grazing-angle artifacts.");

	// ---- Temporal Stabilization ---------------------------------------------
	if (ImGui::TreeNodeEx("Temporal Stabilization##ssdm", ImGuiTreeNodeFlags_DefaultOpen)) {
		ImGui::Checkbox("Enable##ssdm_temporal", &settings.EnableTemporalStabilization);
		if (auto _tt = Util::HoverTooltipWrapper())
			ImGui::Text("Accumulates depth over multiple frames to suppress flickering.");

		if (settings.EnableTemporalStabilization) {
			ImGui::SliderFloat("Blend Alpha##ssdm", &settings.MinBlendAlpha, 0.02f, 0.5f, "%.3f");
			if (auto _tt = Util::HoverTooltipWrapper())
				ImGui::Text("Minimum blend weight of the current frame when converged.\n"
					"Lower = more stable, higher = faster response to movement.");

			ImGui::SliderInt("Max Accum Frames##ssdm", (int*)&settings.MaxAccumFrames, 8, 64);
			if (auto _tt = Util::HoverTooltipWrapper())
				ImGui::Text("Frames needed to reach full temporal convergence.");
		}
		ImGui::TreePop();
	}

	// ---- Spatial Blur -------------------------------------------------------
	if (ImGui::TreeNodeEx("Spatial Blur##ssdm", ImGuiTreeNodeFlags_DefaultOpen)) {
		ImGui::Checkbox("Enable##ssdm_blur", &settings.EnableBlur);
		if (auto _tt = Util::HoverTooltipWrapper())
			ImGui::Text("Cross-bilateral blur to smooth residual noise after temporal accumulation.");

		if (settings.EnableBlur) {
			ImGui::SliderInt("Radius##ssdm", (int*)&settings.BlurRadius, 1, 3);
			if (auto _tt = Util::HoverTooltipWrapper())
				ImGui::Text("Blur kernel radius in pixels.");

			ImGui::SliderFloat("Depth Sigma##ssdm", &settings.BlurDepthSigma, 0.01f, 1.0f, "%.3f");
			if (auto _tt = Util::HoverTooltipWrapper())
				ImGui::Text("Depth-based edge-stopping sigma. Lower = sharper depth boundaries.");
		}
		ImGui::TreePop();
	}

	ImGui::Unindent();
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

	// ---- Temporal history (ping-pong, R32_FLOAT, same dims as texRefinedDepth) ---
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
			auto name = fmt::format("SSDM::RefinedDepthHistory{}", i);
			texRefinedDepthHistory[i] = eastl::make_unique<Texture2D>(texDesc, name.c_str());
			texRefinedDepthHistory[i]->CreateSRV({
				.Format        = DXGI_FORMAT_R32_FLOAT,
				.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
				.Texture2D     = { .MostDetailedMip = 0, .MipLevels = 1 } });
			texRefinedDepthHistory[i]->CreateUAV({
				.Format        = DXGI_FORMAT_R32_FLOAT,
				.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
				.Texture2D     = { .MipSlice = 0 } });
		}
	}

	// ---- Per-pixel accumulation counter (R8_UINT, [0..MaxAccumFrames]) ------
	{
		D3D11_TEXTURE2D_DESC texDesc{
			.Width      = mainDesc.Width,
			.Height     = mainDesc.Height,
			.MipLevels  = 1,
			.ArraySize  = 1,
			.Format     = DXGI_FORMAT_R8_UINT,
			.SampleDesc = { .Count = 1, .Quality = 0 },
			.Usage      = D3D11_USAGE_DEFAULT,
			.BindFlags  = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS,
		};
		texAccumCount = eastl::make_unique<Texture2D>(texDesc, "SSDM::AccumCount");
		texAccumCount->CreateSRV({
			.Format        = DXGI_FORMAT_R8_UINT,
			.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
			.Texture2D     = { .MostDetailedMip = 0, .MipLevels = 1 } });
		texAccumCount->CreateUAV({
			.Format        = DXGI_FORMAT_R8_UINT,
			.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
			.Texture2D     = { .MipSlice = 0 } });
	}

	// ---- Constant buffer ----------------------------------------------------
	ssdmCB = eastl::make_unique<ConstantBuffer>(ConstantBufferDesc<SSDMCB>());

	ClearShaderCache();
}

void ScreenSpaceDisplacementMapping::ClearShaderCache()
{
	csPrefilterDepth = nullptr;
	csDisplace       = nullptr;
	csTemporal       = nullptr;
	csBlur           = nullptr;
	recompileFlag    = true;
	firstFrameTemporal = true;

	const auto shaderDir = std::filesystem::path("Data\\Shaders\\ScreenSpaceDisplacementMapping");

	if (auto* raw = reinterpret_cast<ID3D11ComputeShader*>(
			Util::CompileShader((shaderDir / "prefilterDepth.cs.hlsl").c_str(), {}, "cs_5_0")))
		csPrefilterDepth.attach(raw);

	if (auto* raw = reinterpret_cast<ID3D11ComputeShader*>(
			Util::CompileShader((shaderDir / "displace.cs.hlsl").c_str(), {}, "cs_5_0")))
		csDisplace.attach(raw);

	if (auto* raw = reinterpret_cast<ID3D11ComputeShader*>(
			Util::CompileShader((shaderDir / "temporal.cs.hlsl").c_str(), {}, "cs_5_0")))
		csTemporal.attach(raw);

	if (auto* raw = reinterpret_cast<ID3D11ComputeShader*>(
			Util::CompileShader((shaderDir / "blur.cs.hlsl").c_str(), {}, "cs_5_0")))
		csBlur.attach(raw);
}

void ScreenSpaceDisplacementMapping::UpdateSSDMCB()
{
	static float4x4 prevInvView[2] = {};
	static float4x4 prevViewMat[2] = {};

	SSDMCB data{};
	const int numEyes = 1 + REL::Module::IsVR();
	for (int eyeIndex = 0; eyeIndex < numEyes; ++eyeIndex) {
		auto     eye        = Util::GetCameraData(eyeIndex);
		float4x4 currInvView = eye.viewMat.Invert();

		data.PrevInvViewMat[eyeIndex]  = prevInvView[eyeIndex];
		data.CurrInvViewMat[eyeIndex]  = currInvView;
		data.PrevViewProjMat[eyeIndex] = prevViewMat[eyeIndex] * eye.projMat;
		data.NDCToViewMul[eyeIndex]    = { 2.0f / eye.projMat(0, 0), -2.0f / eye.projMat(1, 1) };
		data.NDCToViewAdd[eyeIndex]    = { -1.0f / eye.projMat(0, 0), 1.0f / eye.projMat(1, 1) };
		if (REL::Module::IsVR())
			data.NDCToViewMul[eyeIndex].x *= 2.0f;

		prevInvView[eyeIndex] = currInvView;
		prevViewMat[eyeIndex] = eye.viewMat;
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

bool ScreenSpaceDisplacementMapping::CameraJumpDetected()
{
	auto     eye        = Util::GetCameraData(0);
	float3   currPos    = eye.viewMat.Invert().Translation();
	bool     jumped     = !firstFrameTemporal &&
	                      (currPos - prevCameraPos).LengthSquared() > 100.0f;
	prevCameraPos      = currPos;
	firstFrameTemporal = false;
	return jumped;
}

void ScreenSpaceDisplacementMapping::DrawSSDM()
{
	if (!loaded || !settings.Enabled)
		return;
	if (!csPrefilterDepth || !texDepthHierarchy)
		return;

	ZoneScoped;

	auto context  = globals::d3d::context;
	auto renderer = globals::game::renderer;
	auto& em      = globals::features::extendedMaterials;

	const uint w = texRefinedDepth[outputIdx] ? texRefinedDepth[outputIdx]->desc.Width  : 0;
	const uint h = texRefinedDepth[outputIdx] ? texRefinedDepth[outputIdx]->desc.Height : 0;

	// Update constant buffer with current frame data.
	UpdateSSDMCB();

	// Bind shared state used by all passes.
	{
		auto* cb       = ssdmCB->CB();
		auto* sharedCB = globals::state->sharedDataCB->CB();
		context->CSSetConstantBuffers(1, 1, &cb);
		context->CSSetConstantBuffers(5, 1, &sharedCB);

		ID3D11SamplerState* samplers[] = { samplerPointClamp.get(), samplerLinearClamp.get() };
		context->CSSetSamplers(0, 2, samplers);
	}

	// --- Pass 1: Prefilter depth pyramid ------------------------------------
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
		context->Dispatch((halfW / 2 + 7) / 8, (halfH / 2 + 7) / 8, 1);

		ID3D11ShaderResourceView*  nullSrv[1] = { nullptr };
		ID3D11UnorderedAccessView* nullUav[5] = {};
		context->CSSetShaderResources(0, 1, nullSrv);
		context->CSSetUnorderedAccessViews(0, 5, nullUav, nullptr);
	}

	// --- Pass 2: Ray-march displace → texRefinedDepth[outputIdx] -----------
	if (csDisplace && w > 0) {
		TracyD3D11Zone(globals::state->tracyCtx, "SSDM - Displace");

		ID3D11ShaderResourceView* srvs[] = {
			Util::GetCurrentSceneDepthSRV(),                               // t0 raw NDC depth
			renderer->GetRuntimeData().renderTargets[NORMALROUGHNESS].SRV, // t1 normals
			em.loaded ? em.GetHeightGBufferSRV() : nullptr,                // t2 parallax height
			texDepthHierarchy->srv.get(),                                  // t3 depth pyramid
		};
		context->CSSetShaderResources(0, ARRAYSIZE(srvs), srvs);

		ID3D11UnorderedAccessView* uav = texRefinedDepth[outputIdx]->uav.get();
		context->CSSetUnorderedAccessViews(0, 1, &uav, nullptr);

		context->CSSetShader(csDisplace.get(), nullptr, 0);
		context->Dispatch((w + 15) / 16, (h + 15) / 16, 1);

		ID3D11ShaderResourceView*  nullSrvs[4] = {};
		ID3D11UnorderedAccessView* nullUav      = nullptr;
		context->CSSetShaderResources(0, ARRAYSIZE(nullSrvs), nullSrvs);
		context->CSSetUnorderedAccessViews(0, 1, &nullUav, nullptr);
	}

	// --- Pass 3: Temporal accumulation → texRefinedDepthHistory[outputIdx] -
	const bool doTemporal = settings.EnableTemporalStabilization && csTemporal &&
	                        texRefinedDepthHistory[0] && texRefinedDepthHistory[1] && texAccumCount;
	if (doTemporal) {
		TracyD3D11Zone(globals::state->tracyCtx, "SSDM - Temporal");

		// Clear accumulation counter on camera cuts to avoid ghost artifacts.
		if (CameraJumpDetected()) {
			uint clearVals[4] = {};
			context->ClearUnorderedAccessViewUint(texAccumCount->uav.get(), clearVals);
		}

		const uint histIdx = 1u - outputIdx;
		ID3D11ShaderResourceView* srvs[] = {
			texRefinedDepth[outputIdx]->srv.get(),         // t0 current virtual depth
			texRefinedDepthHistory[histIdx]->srv.get(),    // t1 previous temporal output
			renderer->GetRuntimeData().renderTargets[NORMALROUGHNESS].SRV, // t2 normals
		};
		context->CSSetShaderResources(0, ARRAYSIZE(srvs), srvs);

		ID3D11UnorderedAccessView* uavs[] = {
			texAccumCount->uav.get(),                    // u0 accumulation counter
			texRefinedDepthHistory[outputIdx]->uav.get() // u1 temporal output
		};
		context->CSSetUnorderedAccessViews(0, ARRAYSIZE(uavs), uavs, nullptr);

		context->CSSetShader(csTemporal.get(), nullptr, 0);
		context->Dispatch((w + 15) / 16, (h + 15) / 16, 1);

		ID3D11ShaderResourceView*  nullSrvs[3] = {};
		ID3D11UnorderedAccessView* nullUavs[2] = {};
		context->CSSetShaderResources(0, ARRAYSIZE(nullSrvs), nullSrvs);
		context->CSSetUnorderedAccessViews(0, ARRAYSIZE(nullUavs), nullUavs, nullptr);
	}

	// --- Pass 4: Cross-bilateral blur → texRefinedDepth[outputIdx] (reuse) -
	// Reads from history (temporal output), writes to the displace buffer (already consumed).
	const bool doBlur = settings.EnableBlur && doTemporal && csBlur;
	if (doBlur) {
		TracyD3D11Zone(globals::state->tracyCtx, "SSDM - Blur");

		ID3D11ShaderResourceView* srvs[] = {
			texRefinedDepthHistory[outputIdx]->srv.get(),                  // t0 temporal output
			renderer->GetRuntimeData().renderTargets[NORMALROUGHNESS].SRV, // t1 normals
		};
		context->CSSetShaderResources(0, ARRAYSIZE(srvs), srvs);

		ID3D11UnorderedAccessView* uav = texRefinedDepth[outputIdx]->uav.get();
		context->CSSetUnorderedAccessViews(0, 1, &uav, nullptr);

		context->CSSetShader(csBlur.get(), nullptr, 0);
		context->Dispatch((w + 15) / 16, (h + 15) / 16, 1);

		ID3D11ShaderResourceView*  nullSrvs[2] = {};
		ID3D11UnorderedAccessView* nullUav      = nullptr;
		context->CSSetShaderResources(0, ARRAYSIZE(nullSrvs), nullSrvs);
		context->CSSetUnorderedAccessViews(0, 1, &nullUav, nullptr);
	}

	// --- Track final SRV before ping-pong flip ------------------------------
	// blur → texRefinedDepth[outputIdx]; temporal-only → texRefinedDepthHistory[outputIdx];
	// displace-only → texRefinedDepth[outputIdx].
	if (doBlur)
		latestOutputSRV = texRefinedDepth[outputIdx]->srv.get();
	else if (doTemporal)
		latestOutputSRV = texRefinedDepthHistory[outputIdx]->srv.get();
	else if (texRefinedDepth[outputIdx])
		latestOutputSRV = texRefinedDepth[outputIdx]->srv.get();
	else
		latestOutputSRV = nullptr;

	// Flip ping-pong index for the next frame.
	outputIdx = 1u - outputIdx;

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
	return latestOutputSRV;
}
