#include "ExtendedMaterials.h"

#include <algorithm>
#include <cstdint>
#include <imgui.h>

#include "Deferred.h"
#include "State.h"
#include "Utils/D3D.h"

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT(
	ExtendedMaterials::Settings,
	EnableComplexMaterial,
	EnableParallax,
	EnableTerrain,
	EnableHeightBlending,
	DisplacementScale)

void ExtendedMaterials::DataLoaded()
{
	if (&settings.EnableTerrain) {
		if (auto bLandSpecular = globals::game::iniSettingCollection->GetSetting("bLandSpecular:Landscape"); bLandSpecular) {
			if (!bLandSpecular->data.b) {
				logger::info("[CPM] Changing bLandSpecular from {} to {} to support Terrain Parallax", bLandSpecular->data.b, true);
				bLandSpecular->data.b = true;
			}
		}
	}
}

void ExtendedMaterials::DrawSettings()
{
	if (ImGui::TreeNodeEx("Complex Material", ImGuiTreeNodeFlags_DefaultOpen)) {
		ImGui::Checkbox("Enable Complex Material", (bool*)&settings.EnableComplexMaterial);
		if (auto _tt = Util::HoverTooltipWrapper()) {
			ImGui::Text(
				"Enables support for the Complex Material specification which makes use of the environment mask. "
				"This includes parallax, as well as more realistic metals and specular reflections. "
				"May lead to some warped textures on modded content which have an invalid alpha channel in their environment mask. ");
		}

		ImGui::Spacing();
		ImGui::Spacing();
		ImGui::TreePop();
	}

	if (ImGui::TreeNodeEx("Screen Space Displacement", ImGuiTreeNodeFlags_DefaultOpen)) {
		if (ImGui::Checkbox("Enable Displacement", (bool*)&settings.EnableParallax)) {
			// DeferredCompositeCS is built with or without SSDM based on this flag; mismatch causes
			// null SRV reads (black sky / corrupt frame) or SSDM appearing to do nothing until cache clear.
			globals::deferred->ClearShaderCache();
		}
		if (auto _tt = Util::HoverTooltipWrapper()) {
			ImGui::Text("Enables screen-space displacement mapping (SSDM) on meshes and terrain.");
		}

		if (ImGui::Checkbox("Enable Legacy Terrain", (bool*)&settings.EnableTerrain)) {
			if (settings.EnableTerrain) {
				DataLoaded();
			}
		}
		if (auto _tt = Util::HoverTooltipWrapper()) {
			ImGui::Text(
				"Enables terrain parallax using the alpha channel of each landscape texture. "
				"Therefore, all landscape textures must support parallax for this effect to work properly. ");
		}
		ImGui::Checkbox("Enable Terrain Height Blending", (bool*)&settings.EnableHeightBlending);
		if (auto _tt = Util::HoverTooltipWrapper()) {
			ImGui::Text("Enables landscape texture blending based on height. ");
		}
		ImGui::SliderFloat("Displacement intensity (× authored)", &settings.DisplacementScale, 0.0f, 4.0f, "%.2f");
		if (auto _tt = Util::HoverTooltipWrapper()) {
			ImGui::Text(
				"Multiplies engine / texture displacement strength (vanilla ParallaxOccData, True PBR height scale, terrain heightmaps). "
				"1 matches authored materials; raise or lower only if you want a global tweak.");
		}

		ImGui::Spacing();
		ImGui::Spacing();
		ImGui::TreePop();
	}

	ImGui::SeparatorText("Debug");

	if (ImGui::TreeNode("Buffer Viewer")) {
		static float debugRescale = .3f;
		ImGui::SliderFloat("View Resize", &debugRescale, 0.f, 1.f);
		ImGui::TextWrapped(
			"Displacement and SSDM targets are RGBA32F; RG are often tiny signed values, so previews can look black or flat even when data is present. "
			"Use the numeric thresholds above or an external capture tool if you need exact duv magnitudes.");

		if (!texDisplacement || !texDisplacement->srv.get()) {
			ImGui::BulletText("Displacement RT not allocated yet (load into the game world after enabling the feature).");
		} else {
			BUFFER_VIEWER_NODE_TITLE(texDisplacement, "Displacement (RG = duv)", debugRescale);
		}

		if (texSSDM && texSSDM->srv.get()) {
			char buf[128];
			snprintf(buf, sizeof(buf), "SSDM solve output (%ux%u)", texSSDM->desc.Width, texSSDM->desc.Height);
			if (ImGui::TreeNode(buf)) {
				ImGui::Image(
					ImTextureRef(static_cast<ImTextureID>(reinterpret_cast<std::uintptr_t>(texSSDM->srv.get()))),
					{ texSSDM->desc.Width * debugRescale, texSSDM->desc.Height * debugRescale });
				ImGui::TreePop();
			}
		}

		ImGui::TreePop();
	}
}

void ExtendedMaterials::LoadSettings(json& o_json)
{
	const bool prevDisplacement = settings.EnableParallax != 0;
	settings = o_json;
	// Older configs stored absolute scale (~0.05 neutral, slider max ~0.2). Convert to multiplier (~1 neutral).
	if (settings.DisplacementScale > 0.001f && settings.DisplacementScale < 0.21f) {
		settings.DisplacementScale = std::clamp(settings.DisplacementScale / 0.05f, 0.25f, 5.0f);
	}
	if (prevDisplacement != (settings.EnableParallax != 0)) {
		globals::deferred->ClearShaderCache();
	}
}

void ExtendedMaterials::SaveSettings(json& o_json)
{
	o_json = settings;
}

void ExtendedMaterials::RestoreDefaultSettings()
{
	settings = {};
	globals::deferred->ClearShaderCache();
}

bool ExtendedMaterials::HasShaderDefine(RE::BSShader::Type shaderType)
{
	switch (shaderType) {
	case RE::BSShader::Type::Lighting:
		return true;
	default:
		return false;
	}
}

void ExtendedMaterials::SetupResources()
{
	auto device = globals::d3d::device;
	auto renderer = globals::game::renderer;
	auto& mainTex = renderer->GetRuntimeData().renderTargets[RE::RENDER_TARGETS::kMAIN];

	D3D11_TEXTURE2D_DESC mainDesc{};
	mainTex.texture->GetDesc(&mainDesc);

	uint w = mainDesc.Width;
	uint h = mainDesc.Height;

	{
		D3D11_TEXTURE2D_DESC texDesc = {
			.Width = w,
			.Height = h,
			.MipLevels = SSDM_MIP_LEVELS,
			.ArraySize = 1,
			.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
			.SampleDesc = { .Count = 1, .Quality = 0 },
			.Usage = D3D11_USAGE_DEFAULT,
			.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET | D3D11_BIND_UNORDERED_ACCESS,
			.CPUAccessFlags = 0,
			.MiscFlags = 0
		};

		texDisplacement = eastl::make_unique<Texture2D>(texDesc);
		texDisplacement->CreateSRV(D3D11_SHADER_RESOURCE_VIEW_DESC{
			.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
			.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
			.Texture2D = { .MostDetailedMip = 0, .MipLevels = SSDM_MIP_LEVELS } });

		CD3D11_RENDER_TARGET_VIEW_DESC rtvDesc(D3D11_RTV_DIMENSION_TEXTURE2D, DXGI_FORMAT_R32G32B32A32_FLOAT, 0);
		DX::ThrowIfFailed(device->CreateRenderTargetView(texDisplacement->resource.get(), &rtvDesc, rtvDisplacement.put()));

		for (int i = 0; i < SSDM_MIP_LEVELS; ++i) {
			D3D11_UNORDERED_ACCESS_VIEW_DESC mipUav = {
				.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
				.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
				.Texture2D = { .MipSlice = (UINT)i }
			};
			DX::ThrowIfFailed(device->CreateUnorderedAccessView(texDisplacement->resource.get(), &mipUav, uavDisplacement[i].put()));

			D3D11_SHADER_RESOURCE_VIEW_DESC mipSrv = {
				.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
				.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
				.Texture2D = { .MostDetailedMip = (UINT)i, .MipLevels = 1 },
			};
			DX::ThrowIfFailed(device->CreateShaderResourceView(texDisplacement->resource.get(), &mipSrv, srvDisplacementMip[i].put()));
		}
	}

	{
		D3D11_TEXTURE2D_DESC ssdmDesc = {
			.Width = w,
			.Height = h,
			.MipLevels = 1,
			.ArraySize = 1,
			.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
			.SampleDesc = { .Count = 1, .Quality = 0 },
			.Usage = D3D11_USAGE_DEFAULT,
			.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS,
			.CPUAccessFlags = 0,
			.MiscFlags = 0
		};
		texSSDM = eastl::make_unique<Texture2D>(ssdmDesc);
		texSSDM->CreateSRV(D3D11_SHADER_RESOURCE_VIEW_DESC{
			.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
			.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D,
			.Texture2D = { .MostDetailedMip = 0, .MipLevels = 1 } });
		texSSDM->CreateUAV(D3D11_UNORDERED_ACCESS_VIEW_DESC{
			.Format = DXGI_FORMAT_R32G32B32A32_FLOAT,
			.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
			.Texture2D = { .MipSlice = 0 } });
	}

	cbufSSDMSolve = eastl::make_unique<ConstantBuffer>(ConstantBufferDesc(sizeof(SSDMSolveCB), false));

	ClearShaderCache();
}

void ExtendedMaterials::ClearShaderCache()
{
	ssdmBuildPyramidCS = nullptr;
	ssdmSolveCS = nullptr;
}

void ExtendedMaterials::RegisterDisplacementRT()
{
	if (!texDisplacement || !rtvDisplacement)
		return;
	auto renderer = globals::game::renderer;
	auto& rt = renderer->GetRuntimeData().renderTargets[SSDM_DISPLACEMENT];
	rt.texture = texDisplacement->resource.get();
	rt.SRV = texDisplacement->srv.get();
	rt.RTV = rtvDisplacement.get();
}

ID3D11ShaderResourceView* ExtendedMaterials::GetSSDMOffsetSRV() const
{
	return (texSSDM && settings.EnableParallax) ? texSSDM->srv.get() : nullptr;
}

void ExtendedMaterials::ClearDisplacementTexture()
{
	if (!rtvDisplacement)
		return;
	const float clearColor[4] = { 0, 0, 0, 0 };
	globals::d3d::context->ClearRenderTargetView(rtvDisplacement.get(), clearColor);
}

void ExtendedMaterials::CompileSSDMComputeShadersIfNeeded()
{
	const std::vector<std::pair<const char*, const char*>> defines{};

	if (!ssdmBuildPyramidCS || !ssdmSolveCS) {
		// Drop any partial state from a previous failed load so we never run solve with stale coarser mips.
		ssdmBuildPyramidCS = nullptr;
		ssdmSolveCS = nullptr;

		winrt::com_ptr<ID3D11ComputeShader> pyramid;
		winrt::com_ptr<ID3D11ComputeShader> solve;

		if (auto* raw = Util::CompileShader(L"Data\\Shaders\\ExtendedMaterials\\SSDMBuildPyramidCS.hlsl", defines, "cs_5_0")) {
			pyramid.attach(reinterpret_cast<ID3D11ComputeShader*>(raw));
			Util::SetResourceName(pyramid.get(), "SSDMBuildPyramidCS");
		} else {
			logger::error("[ExtendedMaterials] Failed to compile SSDMBuildPyramidCS.hlsl");
		}
		if (auto* raw = Util::CompileShader(L"Data\\Shaders\\ExtendedMaterials\\SSDMSolveCS.hlsl", defines, "cs_5_0")) {
			solve.attach(reinterpret_cast<ID3D11ComputeShader*>(raw));
			Util::SetResourceName(solve.get(), "SSDMSolveCS");
		} else {
			logger::error("[ExtendedMaterials] Failed to compile SSDMSolveCS.hlsl");
		}

		if (pyramid && solve) {
			ssdmBuildPyramidCS = std::move(pyramid);
			ssdmSolveCS = std::move(solve);
		}
	}
}

void ExtendedMaterials::DrawSSDM()
{
	if (!settings.EnableParallax)
		return;
	if (!texDisplacement || !texSSDM || !cbufSSDMSolve)
		return;

	CompileSSDMComputeShadersIfNeeded();
	if (!ssdmBuildPyramidCS || !ssdmSolveCS)
		return;

	ZoneScoped;
	TracyD3D11Zone(globals::state->tracyCtx, "SSDM");

	auto context = globals::d3d::context;
	auto* deferred = Deferred::GetSingleton();
	if (!deferred || !deferred->pointSampler)
		return;

	const UINT fullW = texDisplacement->desc.Width;
	const UINT fullH = texDisplacement->desc.Height;

	ID3D11ShaderResourceView* duvSRV = texDisplacement->srv.get();

	for (int dstMip = 1; dstMip < SSDM_MIP_LEVELS; ++dstMip) {
		const int srcMip = dstMip - 1;
		ID3D11ShaderResourceView* srcSrv = srvDisplacementMip[srcMip].get();
		context->CSSetShaderResources(0, 1, &srcSrv);
		ID3D11UnorderedAccessView* dstUav = uavDisplacement[dstMip].get();
		context->CSSetUnorderedAccessViews(0, 1, &dstUav, nullptr);
		context->CSSetShader(ssdmBuildPyramidCS.get(), nullptr, 0);
		const UINT mw = std::max(1u, fullW >> dstMip);
		const UINT mh = std::max(1u, fullH >> dstMip);
		context->Dispatch((mw + 7u) / 8u, (mh + 7u) / 8u, 1);
	}

	ID3D11ShaderResourceView* nullSrv = nullptr;
	ID3D11UnorderedAccessView* nullUav = nullptr;
	context->CSSetShaderResources(0, 1, &nullSrv);
	context->CSSetUnorderedAccessViews(0, 1, &nullUav, nullptr);

	SSDMSolveCB solveData{};
	solveData.fullWidth = static_cast<float>(fullW);
	solveData.fullHeight = static_cast<float>(fullH);
	solveData.rcpFullWidth = fullW ? 1.0f / static_cast<float>(fullW) : 0.0f;
	solveData.rcpFullHeight = fullH ? 1.0f / static_cast<float>(fullH) : 0.0f;
	solveData.numMips = SSDM_MIP_LEVELS;
	solveData.numIters = 8;
	solveData.maxStepUv = 0.35f;  // Keep in sync with ExtendedMaterials.hlsli kSSDMDuvClampAbs (forward duv clamp).
	solveData.damping = 0.62f;
	cbufSSDMSolve->Update(solveData);
	ID3D11Buffer* cbSolve = cbufSSDMSolve->CB();
	context->CSSetConstantBuffers(0, 1, &cbSolve);
	context->CSSetShaderResources(0, 1, &duvSRV);
	ID3D11SamplerState* solveSamplers[] = { deferred->pointSampler };
	context->CSSetSamplers(0, 1, solveSamplers);
	ID3D11UnorderedAccessView* outUav = texSSDM->uav.get();
	context->CSSetUnorderedAccessViews(0, 1, &outUav, nullptr);
	context->CSSetShader(ssdmSolveCS.get(), nullptr, 0);
	context->Dispatch((fullW + 7u) / 8u, (fullH + 7u) / 8u, 1);

	context->CSSetShader(nullptr, nullptr, 0);
	context->CSSetShaderResources(0, 1, &nullSrv);
	context->CSSetUnorderedAccessViews(0, 1, &nullUav, nullptr);
	ID3D11SamplerState* nullSamps[] = { nullptr };
	context->CSSetSamplers(0, 1, nullSamps);
	ID3D11Buffer* nullCb = nullptr;
	context->CSSetConstantBuffers(0, 1, &nullCb);
}
