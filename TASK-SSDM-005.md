# TASK-SSDM-005: Compute Shader Principal de Deslocamento (displace.cs.hlsl)

**Épico:** EPIC-SSDM
**Labels:** `shader`, `hlsl`, `compute`, `raymarching`, `core-algorithm`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 5 story points

---

## Descrição

Implementar o compute shader principal do SSDM (`displace.cs.hlsl`) que executa o raymarching em screen-space para calcular o deslocamento aparente de cada pixel com base na altura do parallax (GBuffer de TASK-SSDM-002/003) e no depth de cena. O output é uma textura de **profundidade virtual** (linear depth em view-space) que representa a posição aparente da superfície com o deslocamento aplicado.

**Arquitetura de saída (distinção crítica):**

- Este shader **NÃO** produz UV redirect (papel exclusivo de ExtendedMaterials via t17).
- Produz `float` (linear depth) em `DXGI_FORMAT_R32_FLOAT` → consumido por SSAO/SSGI em Task 7.
- Superfícies com geometria variada (terrain): ray-march encontra depth real da posição deslocada.
- Superfícies planas com parallax (paredes, pisos): fallback H-based (`linearDepth - H*scale`) garante virtual depth útil mesmo sem hit no ray-march.

Este é o shader de maior complexidade técnica do EPIC-SSDM.

## Escopo

- Criar `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/displace.cs.hlsl`.
- Criar recursos GPU de output em `SetupResources()`: `texRefinedDepth[2]` (ping-pong para temporal).
- Implementar o loop de raymarching com busca binária de refinamento.
- Implementar fade em ângulo rasante e distância máxima.
- Implementar fallback gracioso para pixels sem dado de altura (SSDM transparente).
- Implementar `DrawSSDM()` em C++ para dispatch do compute.

## Detalhes técnicos

**Algoritmo SSDM (por pixel):**

```text
1. Ler depth raw → converter para depth linear → reconstruir posição view-space P
2. Ler normal de GBuffer → decodificar normal de superfície N
3. Ler altura H do HeightGBuffer (de ExtendedMaterials)
   - Se H ≈ 0: pixel não tem parallax → copiar depth original, encerrar
4. Calcular vetor view V = normalize(-P)  (câmera está na origem em view-space)
5. Calcular ângulo de incidência θ = dot(V, N)
   - Se θ < FadeAngleCos: fade out gradual do efeito
6. Calcular deslocamento máximo em view-space:
   D_max = H * DisplacementScale * MaxDisplacementDist
7. Construir ray origin = P, ray direction = -V (do pixel em direção à câmera)
8. Marchar o ray em NumRaymarchSteps passos uniformes de D_max / NumSteps
   - Para cada passo:
     a. Projetar posição de ray para screen UV
     b. Se UV fora da tela: encerrar (sem deslocamento)
     c. Amostrar depth hierárquico nessa posição
     d. Verificar se ray passou abaixo da superfície (intersecção)
9. Se intersecção encontrada: refinar com busca binária (NumBinarySearchSteps passos)
10. Output: escrever depth view-space refinado em texRefinedDepth[outputIdx]
```

**Thread group e dispatch:**

```hlsl
[numthreads(16, 16, 1)]
void CS(uint3 DTid : SV_DispatchThreadID, uint2 GTid : SV_GroupThreadID)
```

Dispatch: `((width + 15) / 16, (height + 15) / 16, 1)`

**Inputs do compute shader:**

- `t0`: depth buffer raw (SRV)
- `t1`: normal GBuffer (NORMALROUGHNESS SRV)
- `t2`: height GBuffer (ExtendedMaterials::HeightGBuffer SRV)
- `t3`: depth hierárquico (SSDM::DepthHierarchy SRV)
- `b1`: SSDMCB (constant buffer)
- `b5`: SharedData (cbuffer global)

**Output:**

- `u0`: `texRefinedDepth[outputIdx]` (UAV) — depth linear refinado por pixel

**Textura de output (C++ `SetupResources()`):**

```cpp
D3D11_TEXTURE2D_DESC desc{
    .Width     = renderWidth,   // ou halfWidth se ResolutionMode > 0
    .Height    = renderHeight,
    .MipLevels = 1,
    .Format    = DXGI_FORMAT_R32_FLOAT,
    .BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS,
};
for (int i = 0; i < 2; ++i)
    texRefinedDepth[i] = eastl::make_unique<Texture2D>(desc, fmt::format("SSDM::RefinedDepth{}", i));
```

**Fade em ângulo rasante:**

```hlsl
float angleFade = saturate((normalDotView - FadeAngleCos) / (1.0f - FadeAngleCos));
float displacementAmount = lerp(0.0f, fullDisplacement, angleFade);
```

**Thickness bias (evitar z-fighting):**

```hlsl
bool SSDMDepthTest(float sampleLinearDepth, float rayLinearDepth)
{
    float thickness = rayLinearDepth * 0.02f;  // 2% da distância como thickness
    return (sampleLinearDepth > rayLinearDepth) &&
           (sampleLinearDepth < rayLinearDepth + thickness);
}
```

## Critérios de Aceitação

- [x] Shader compila sem erros com hlslkit. *(fxc /D COMPUTESHADER: 0 erros, 0 warnings, 125 instruction slots)*
- [ ] No RenderDoc, `texRefinedDepth` contém values > 0 em pixels com parallax activo.
- [ ] Pixels sem parallax têm depth refinado == depth original (fallback correto).
- [ ] Fade em ângulo rasante funciona — deslocamento desaparece progressivamente em ângulos > FadeAngle.
- [ ] Sem artefatos visíveis de z-fighting em superfícies planas próximas.
- [ ] Performance: não mais que 2ms de overhead de GPU em cena típica (medir com Tracy ou RenderDoc).
- [ ] VR: dispatch ocorre para ambos os olhos com eye index correto.
- [ ] `NumRaymarchSteps = 1` (mínimo) não causa crash — deve simplesmente não deslocar.

## Arquivos / áreas afetadas

- `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/displace.cs.hlsl` (**novo**)
- `src/Features/ScreenSpaceDisplacementMapping.h` (adicionar `texRefinedDepth[2]`, `csDisplace`, `outputIdx`)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (implementar `DrawSSDM()` com dispatch; criar recursos em `SetupResources()`)

## Dependências

- TASK-SSDM-001 (feature C++ skeleton)
- TASK-SSDM-002 (HeightGBuffer SRV disponível)
- TASK-SSDM-003 (dados de altura escritos no HeightGBuffer)
- TASK-SSDM-004 (utilitários `common.hlsli` + `texDepthHierarchy`)

## Observações

- Referência de algoritmo: <https://www.divideconcept.net/papers/SSDM-RL08.pdf> (seção 3 — Screen-Space Raymarching).
- O raymarching ocorre em **view-space**, não em tangent-space como o POM. Isso é fundamental: as posições e direções devem ser em coordenadas de câmera.
- A busca binária de refinamento não é obrigatória para a primeira versão — pode ser omitida com `NumBinarySearchSteps = 0` como caso de uso inicial.
- Evitar leituras de depth via SRV do depth buffer real do Skyrim — usar o depth hierárquico criado em TASK-SSDM-004, que é uma cópia com mips. O depth original pode não ser bindable como SRV sem cópia.
- Compilar o shader com variantes: `#define SSDM_HALF_RES` para o modo half-resolution, sem define para full-res. Usar o `recompileFlag` pattern de `ScreenSpaceGI` quando `ResolutionMode` mudar.
