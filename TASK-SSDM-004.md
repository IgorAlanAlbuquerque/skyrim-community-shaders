# TASK-SSDM-004: Utilitários HLSL Compartilhados e Pré-filtragem de Depth

**Épico:** EPIC-SSDM
**Labels:** `shader`, `hlsl`, `utilities`, `depth`, `compute`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 2 story points

---

## Descrição

Criar o arquivo de utilitários HLSL compartilhados (`common.hlsli`) para os compute shaders do SSDM, adaptando os utilitários já existentes em `ScreenSpaceGI/common.hlsli`. Implementar também o compute shader de pré-filtragem de depth (`prefilterDepth.cs.hlsl`) que constrói uma hierarquia de mips de profundidade para otimizar o raymarching da TASK-SSDM-005.

## Escopo

- Criar `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/common.hlsli`.
- Criar `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/prefilterDepth.cs.hlsl`.
- Garantir que `common.hlsli` cobre todas as funções auxiliares necessárias para TASK-SSDM-005 e TASK-SSDM-006.
- Criar textura de depth hierárquico (mip chain) em `ScreenSpaceDisplacementMapping::SetupResources()`.

## Detalhes técnicos

**`common.hlsli` — funções obrigatórias:**

```hlsl
// Reconstrução de posição view-space a partir de screen UV e depth
float3 SSDMScreenToViewPos(float2 screenUV, float linearDepth, uint eyeIndex);

// Converter depth buffer raw para depth linear (view-space Z)
float SSDMRawToLinearDepth(float rawDepth);

// Converter posição view-space para screen UV (para raymarching)
float2 SSDMViewPosToScreenUV(float3 viewPos, uint eyeIndex);

// Validar se um UV está dentro dos bounds da tela
bool SSDMIsValidUV(float2 uv);

// Comparar dois depths para teste de oclusão
bool SSDMDepthTest(float sampleDepth, float rayDepth, float thickness);
```

Estas funções devem ser implementadas com base nos equivalentes de `features/Screen Space GI/Shaders/ScreenSpaceGI/common.hlsli` (`ScreenToViewPosition`, `ScreenToViewDepth`, etc.).

**Constante buffer do SSDM (cbuffer b1):**
```hlsl
cbuffer SSDMCB : register(b1)
{
    float4x4 PrevInvViewMat[2];      // Para reprojection temporal (VR: 2 olhos)
    float4   NDCToViewMul[2];        // Scalars NDC→view (VR: 2 olhos)
    float4   NDCToViewAdd[2];
    float2   RcpFrameDim;            // 1/width, 1/height
    float2   FrameDim;               // width, height
    uint     FrameIndex;             // Para padrões de amostragem temporal
    float    DisplacementScale;      // Multiplicador global de deslocamento
    float    MaxDisplacementDist;    // Distância máxima de raymarching em view-space
    float    FadeAngleCos;           // cos(FadeAngle) para fade em ângulo rasante
    uint     NumRaymarchSteps;       // Passos do raymarching primário
    uint     NumBinarySearchSteps;   // Passos de refinamento binário
    uint     ResolutionMode;         // 0=full, 1=half, 2=quarter
    uint     pad;
}
```

**`prefilterDepth.cs.hlsl`:**
- Input: depth buffer scene (SRV)
- Output: textura de depth com mip chain (UAV com slices)
- Algoritmo: para cada mip, tomar o máximo de depth dos 4 texels do mip anterior (depth conservativo — garante que o raymarching não passe por geometria)
- Thread group: `[numthreads(8, 8, 1)]`
- Dispatch: uma pass por mip level (5 passes para textura 1/2 res → 1/32 res)

**Textura de depth hierárquico (C++ — `SetupResources()`):**
```cpp
D3D11_TEXTURE2D_DESC desc{
    .Width     = halfWidth,
    .Height    = halfHeight,
    .MipLevels = 5,    // hierarquia de 5 níveis
    .Format    = DXGI_FORMAT_R32_FLOAT,
    .BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS,
};
texDepthHierarchy = eastl::make_unique<Texture2D>(desc, "SSDM::DepthHierarchy");
// Criar UAV por mip:
for (uint i = 0; i < 5; ++i) {
    D3D11_UNORDERED_ACCESS_VIEW_DESC uavDesc{
        .Format        = DXGI_FORMAT_R32_FLOAT,
        .ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D,
        .Texture2D     = { .MipSlice = i }
    };
    device->CreateUnorderedAccessView(..., &uavDesc, uavDepthHierarchy[i].put());
}
```

## Critérios de Aceitação

- [ ] `common.hlsli` compila sem erros isoladamente (sem dependências circulares).
- [ ] `prefilterDepth.cs.hlsl` compila com hlslkit sem warnings.
- [ ] Hierarquia de depth visível no RenderDoc com 5 mip levels preenchidos corretamente.
- [ ] Mip N+1 contém o máximo de depth do mip N (verificável no RenderDoc comparando slices).
- [ ] Funções de `common.hlsli` são suficientes para implementar TASK-SSDM-005 sem adicionar utilitários extras.
- [ ] Compilação C++ sem erros com os novos recursos em `SetupResources()`.

## Arquivos / áreas afetadas

- `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/common.hlsli` (**novo**)
- `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/prefilterDepth.cs.hlsl` (**novo**)
- `src/Features/ScreenSpaceDisplacementMapping.h` (adicionar `texDepthHierarchy`, `uavDepthHierarchy[5]`, `csPrefilterDepth`)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (criar recursos e compilar shader em `SetupResources()`)

## Dependências

- TASK-SSDM-001 (classe C++ da feature deve existir)

## Observações

- Referência primária para `common.hlsli`: `features/Screen Space GI/Shaders/ScreenSpaceGI/common.hlsli` — adaptar `ScreenToViewPosition()` e `ScreenToViewDepth()` para o namespace SSDM.
- O depth hierárquico usa metade da resolução do backbuffer como base (`halfWidth = renderWidth / 2`), pois SSDM provavelmente roda em half-res por padrão (configurável via `ResolutionMode`).
- Verificar se `SharedData.hlsli` já exporta `CameraData` suficiente para `SSDMRawToLinearDepth()` antes de duplicar dados no `SSDMCB`.
- Nomear UAVs por mip: `"SSDM::DepthHierarchy UAV mip0"`, `"SSDM::DepthHierarchy UAV mip1"`, etc.
