# TASK-SSDM-008: UI ImGui, Serialização JSON e Arquivo INI

**Épico:** EPIC-SSDM
**Labels:** `feature`, `cpp`, `ui`, `imgui`, `settings`, `json`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 2 story points

---

## Descrição

Implementar a interface de configuração ImGui, a serialização/deserialização JSON e o arquivo de metadados `.ini` da feature SSDM. O settings struct final deve ser definido aqui (foi mantido incompleto nas tasks anteriores) e sincronizado com o `SSDMCB` do shader.

## Escopo

- Definir o `Settings` struct completo e final com todos os parâmetros de tuning.
- Implementar `DrawSettings()` com controles ImGui organizados e dicas de performance.
- Implementar `LoadSettings()` e `SaveSettings()` com `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT`.
- Implementar `RestoreDefaultSettings()`.
- Finalizar o arquivo `.ini` com versão e metadados Nexus placeholder.
- Implementar atualização do `SSDMCB` a partir do `Settings` em `DrawSSDM()`.
- Adicionar `GetFeatureSummary()` com descrição e bullets da feature.
- Adicionar flag `recompileFlag` para settings que mudam variantes de shader (ex: `ResolutionMode`).

## Detalhes técnicos

**`Settings` struct final:**

```cpp
struct alignas(16) Settings {
    // Geral
    bool  Enabled                    = true;
    bool  EnableTemporalStabilization = true;
    bool  EnableBlur                  = true;

    // Raymarching
    uint  NumRaymarchSteps           = 8;       // range: [4, 32]
    uint  NumBinarySearchSteps       = 4;       // range: [0, 8]
    float DisplacementScale          = 1.0f;    // range: [0.1, 3.0]
    float MaxDisplacementDist        = 0.5f;    // metros view-space, range: [0.05, 2.0]

    // Qualidade
    uint  ResolutionMode             = 1;       // 0=Full, 1=Half, 2=Quarter
    float FadeAngle                  = 70.0f;   // graus, range: [30, 85]

    // Temporal
    float MinBlendAlpha              = 0.08f;   // range: [0.02, 0.5]
    uint  MaxAccumFrames             = 32;      // range: [8, 64]

    // Blur
    uint  BlurRadius                 = 1;       // range: [1, 3] — raio do kernel bilateral
    float BlurDepthSigma             = 0.1f;    // range: [0.01, 1.0]
} settings;
```

**`DrawSettings()` — estrutura de UI:**

```
[✓] Enable Screen-Space Displacement Mapping
  → Tooltip: "Refines apparent surface depth for parallax materials."

[Raymarching]
  Steps: slider 4–32  | "Higher = more accurate, more expensive"
  Binary Refinement: slider 0–8 | "Sub-step precision"
  Scale: slider 0.1–3.0 | "Displacement intensity multiplier"
  Max Distance: slider 0.05–2.0 m | "Maximum raymarch distance"

[Quality]
  Resolution: combo [Full / Half (Recommended) / Quarter]
    → Se mudar: recompileFlag = true
  Fade Angle: slider 30–85°

[Temporal Stabilization] (collapsible)
  [✓] Enable
  Blend Alpha: slider 0.02–0.5
  Max Accumulation Frames: slider 8–64

[Spatial Blur] (collapsible)
  [✓] Enable
  Radius: slider 1–3
  Depth Sigma: slider 0.01–1.0

[!] Performance Note: SSDM adds a compute pass per frame.
    Half-resolution is recommended for most hardware.
    Use "Disable at Boot" if framerate impact is unacceptable.
```

**Serialização JSON:**

```cpp
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
    BlurDepthSigma
)
```

**`GetFeatureSummary()`:**

```cpp
std::pair<std::string, std::vector<std::string>> GetFeatureSummary() override
{
    return {
        "Refines apparent surface geometry by raymarching height data in screen-space, "
        "improving SSAO, SSGI and SSR integration for parallax materials.",
        {
            "Screen-space raymarching against parallax height fields",
            "Temporal accumulation for stable results",
            "Improved SSAO/SSGI depth accuracy on textured surfaces",
            "Fade at grazing angles to minimize artifacts",
        }
    };
}
```

**Arquivo `.ini` final:**

```ini
[Info]
Version = 1-0-0

[Nexus]
nexusmodid = 0
nexusfilegroupid = 0
nexusfilename = Screen Space Displacement Mapping
autoupload = false
```

**Atualização do SSDMCB em `DrawSSDM()`:**

```cpp
SSDMCB cbData{};
cbData.DisplacementScale    = settings.DisplacementScale;
cbData.MaxDisplacementDist  = settings.MaxDisplacementDist;
cbData.FadeAngleCos         = cosf(XMConvertToRadians(settings.FadeAngle));
cbData.NumRaymarchSteps     = settings.NumRaymarchSteps;
cbData.NumBinarySearchSteps = settings.NumBinarySearchSteps;
cbData.ResolutionMode       = settings.ResolutionMode;
cbData.MinBlendAlpha        = settings.MinBlendAlpha;
cbData.MaxAccumFrames       = settings.MaxAccumFrames;
// ... matrizes e dimensões ...
ssdmCB->Update(cbData);
```

## Critérios de Aceitação

- [ ] Feature aparece no menu de Community Shaders com categoria e summary corretos.
- [ ] Todos os sliders têm ranges válidos e tooltips descritivos.
- [ ] Salvar/carregar settings persiste todos os campos corretamente entre sessões.
- [ ] `RestoreDefaultSettings()` reseta para valores iniciais do struct.
- [ ] Mudar `ResolutionMode` aciona `recompileFlag` e recompila os shaders afetados.
- [ ] Performance Note aparece no UI quando steps > 16 (aviso de custo alto).
- [ ] Arquivo `.ini` é carregado sem erros pelo sistema de versioning no boot.
- [ ] `GetFeatureSummary()` retorna strings não-vazias (visíveis no tooltip da feature no menu).

## Arquivos / áreas afetadas

- `src/Features/ScreenSpaceDisplacementMapping.h` (struct Settings finalizado + GetFeatureSummary)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (DrawSettings, LoadSettings, SaveSettings, RestoreDefaultSettings, atualização do CB)
- `features/Screen-Space Displacement Mapping/Shaders/Features/ScreenSpaceDisplacementMapping.ini` (versão final)

## Dependências

- TASK-SSDM-001 (esqueleto C++ onde Settings será embutido)
- TASK-SSDM-004 (SSDMCB struct definido no shader — deve estar em sincronia com Settings)

## Observações

- O `Settings` struct usa `alignas(16)` mas não é mapeado diretamente para o shader como um UBO — o `SSDMCB` é um struct separado (não alinhamento idêntico requerido). Manter os dois sincronizados manualmente em `DrawSSDM()`.
- Seguir o padrão de `ScreenSpaceGI::DrawSettings()` para a estrutura visual: começar com toggle principal, depois parâmetros agrupados, depois configurações avançadas em collapsibles.
- Não usar `ImGui::SliderInt` para `NumRaymarchSteps` se o valor for usado como #define de shader — nesse caso, deve ser uma lista de presets (ex: Low/Medium/High) que muda a variante de shader, não um slider contínuo.
- Incluir `imgui_stdlib.h` se necessário para inputs de texto (ex: campos futuros de debug).
