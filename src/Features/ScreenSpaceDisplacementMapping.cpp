#include "ScreenSpaceDisplacementMapping.h"

#include "Deferred.h"
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
	// GPU resources will be created in TASK-SSDM-005
}

void ScreenSpaceDisplacementMapping::ClearShaderCache()
{
	csDisplace = nullptr;
	recompileFlag = true;
}

void ScreenSpaceDisplacementMapping::DrawSSDM()
{
	// Compute dispatch implementation in TASK-SSDM-005
}
