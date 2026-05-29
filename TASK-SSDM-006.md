# TASK-SSDM-006: Estabilização Temporal e Denoising Espacial

**Épico:** EPIC-SSDM
**Labels:** `shader`, `hlsl`, `compute`, `temporal`, `denoising`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 4 story points

---

## Descrição

Implementar o estágio de acumulação temporal (`temporal.cs.hlsl`) que reprojecta o frame anterior de depth refinado para suprimir flickering e instabilidade de borda — a maior fraqueza técnica do SSDM. Implementar também um passo de denoising espacial leve (`blur.cs.hlsl`) para suavizar bordas ruidosas após o temporal.

Sem esta task, o SSDM produzirá shimering intenso especialmente em movimento de câmera, tornando o efeito inutilizável em prática.

## Escopo

- Criar `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/temporal.cs.hlsl`.
- Criar `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/blur.cs.hlsl`.
- Adicionar buffer de acumulação de frames (`texAccumCount`) para controle de convergência.
- Adicionar `texRefinedDepthHistory[2]` separado de `texRefinedDepth[2]` para histórico temporal.
- Implementar flip do índice ping-pong em `DrawSSDM()` após dispatch temporal.
- Garantir reset do histórico em eventos de câmera (teleport, cut de cena).

## Detalhes técnicos

**`temporal.cs.hlsl` — algoritmo de reprojection:**

```
Para cada pixel (x, y):
1. Ler depth refinado atual de texRefinedDepth[currentIdx]
2. Reconstruir posição world-space P_curr a partir do depth e das matrizes atuais
3. Reprojetar P_curr para screen UV do frame anterior usando PrevInvViewMat + PrevProjMat
4. Se UV reprojected fora da tela: sem histórico → output = depth atual (sem blend)
5. Ler depth refinado histórico de texRefinedDepth[1 - currentIdx] no UV reprojected
6. Validação de disocclusion:
   - Depth delta: |curr_depth - hist_depth| > threshold → rejeitar história
   - Normal delta: dot(curr_normal, hist_normal) < threshold → rejeitar história
7. Se história válida: blend exponencial
   float alpha = 0.1f;  // 10% atual, 90% histórico
   output = lerp(hist_depth, curr_depth, alpha);
8. Escrever output em texRefinedDepthHistory[outputIdx]
9. Incrementar texAccumCount (clampar em MaxAccumFrames)
```

**Blend adaptativo baseado em confiança:**
```hlsl
float confidence = saturate(accumCount / MaxAccumFrames);
float blendAlpha = lerp(1.0f, MinBlendAlpha, confidence);
// blendAlpha = 1.0 no primeiro frame (sem histórico), ≈0.05-0.1 quando convergido
```

**Constantes adicionais no SSDMCB (de TASK-SSDM-004):**
```hlsl
float4x4 PrevInvViewMat[2];   // já declarado
float4x4 CurrInvViewMat[2];   // inversa da view atual
float4x4 PrevProjMat[2];      // projeção do frame anterior
float    MinBlendAlpha;        // alpha mínimo quando convergido (default: 0.08)
uint     MaxAccumFrames;       // frames para convergência (default: 32)
```

**`blur.cs.hlsl` — cross-bilateral blur:**
```
Para cada pixel:
1. Ler depth refinado de texRefinedDepthHistory[currentIdx]
2. Para cada vizinho em kernel 3×3 (ou 5×5 configurável):
   - Peso por proximidade de depth (profundidade similar → peso maior)
   - Peso por proximidade de normal (normal similar → peso maior)
   - Peso gaussiano por distância espacial
3. Output: média ponderada no UAV final
```

**Texturas adicionais (`SetupResources()`):**
```cpp
// História temporal — separada das texturas de output atual
for (int i = 0; i < 2; ++i)
    texRefinedDepthHistory[i] = eastl::make_unique<Texture2D>(depthDesc, fmt::format("SSDM::RefinedDepthHistory{}", i));

// Contador de acumulação por pixel
D3D11_TEXTURE2D_DESC accumDesc{ ..., .Format = DXGI_FORMAT_R8_UINT, ... };
texAccumCount = eastl::make_unique<Texture2D>(accumDesc, "SSDM::AccumCount");
```

**Reset de histórico (em `Prepass()` C++):**
```cpp
// Detectar camera cut via grande mudança em view matrix
if (CameraJumpDetected()) {
    float clearVal[4] = { 0.f };
    context->ClearUnorderedAccessViewFloat(texAccumCount->uav.get(), clearVal);
}
```

**Ordem de passes em `DrawSSDM()`:**
```
1. Dispatch prefilterDepth   → texDepthHierarchy
2. Dispatch displace         → texRefinedDepth[outputIdx]
3. Dispatch temporal         → texRefinedDepthHistory[outputIdx]
4. Dispatch blur             → texFinalRefinedDepth  (textura final para downstream)
5. outputIdx = 1 - outputIdx (flip ping-pong)
```

## Critérios de Aceitação

- [ ] Sem flickering visível em câmera parada após ~30 frames de convergência.
- [ ] Camera cut (teleport) reseta o histórico corretamente — sem ghost artifacts.
- [ ] Denoising blur preserva bordas de profundidade (não blura atravessando mudanças abruptas de depth).
- [ ] `texAccumCount` acumula corretamente até `MaxAccumFrames` e para (no RenderDoc valores chegam a MaxAccumFrames).
- [ ] Ambos `temporal.cs.hlsl` e `blur.cs.hlsl` compilam sem erros com hlslkit.
- [ ] VR: reprojection usa matrizes por eye (`eyeIndex`).
- [ ] Movimento rápido de câmera não produz ghosting excessivo (reprojection invalida histórico quando necessário).

## Arquivos / áreas afetadas

- `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/temporal.cs.hlsl` (**novo**)
- `features/Screen-Space Displacement Mapping/Shaders/ScreenSpaceDisplacementMapping/blur.cs.hlsl` (**novo**)
- `src/Features/ScreenSpaceDisplacementMapping.h` (adicionar `texRefinedDepthHistory[2]`, `texAccumCount`, `texFinalRefinedDepth`, `csTemporal`, `csBlur`)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (criar recursos, atualizar `DrawSSDM()` com sequência de 4 passes)
- `src/Features/ScreenSpaceDisplacementMapping.h` / `.cpp` (adicionar `CameraJumpDetected()` helper)

## Dependências

- TASK-SSDM-004 (utilitários common.hlsli, constante buffer SSDMCB)
- TASK-SSDM-005 (output `texRefinedDepth[2]` que serve de input para o temporal)

## Observações

- Referência de reprojection: `features/Screen Space GI/Shaders/ScreenSpaceGI/radianceDisocc.cs.hlsl` — o padrão de `readHistory()` com bilinear taps e validação de disocclusion é diretamente adaptável.
- O blur cross-bilateral é opcional na primeira versão — pode ser pulado com `EnableBlur = false` no settings para reduzir overhead e simplificar a implementação inicial.
- O threshold de disocclusion de depth deve ser em view-space linear, não raw. Valor inicial sugerido: `0.1f` (10cm em unidades de Skyrim).
- Detecção de camera cut: comparar a posição de câmera do frame anterior com a atual — se a distância exceder um threshold (ex: 10 unidades de Skyrim), considerar como cut.
