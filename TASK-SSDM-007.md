# TASK-SSDM-007: Integração com Pipeline Deferred e Efeitos Downstream

**Épico:** EPIC-SSDM
**Labels:** `feature`, `cpp`, `hlsl`, `deferred`, `ssao`, `ssgi`, `integration`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 3 story points

---

## Descrição

Conectar o output de profundidade refinada do SSDM (`texFinalRefinedDepth`) aos efeitos screen-space downstream que se beneficiam de depth mais preciso: SSAO (via ScreenSpaceGI) e SSR (ScreenSpaceReflections). Isso é o objetivo principal do SSDM — fazer com que SSAO, SSGI e SSR "enxerguem" o deslocamento geométrico aparente do parallax.

Esta task também finaliza a integração no `Deferred.cpp`, garantindo que a ordem de passes está correta e que os efeitos downstream recebem o SRV certo.

## Escopo

- Finalizar o hook de `DrawSSDM()` em `src/Deferred.cpp` com a ordem correta no pipeline.
- Expor `GetFinalRefinedDepthSRV()` em `ScreenSpaceDisplacementMapping` para consumo downstream.
- Modificar `ScreenSpaceGI` para usar o depth refinado do SSDM como input de AO/GI quando SSDM está loaded.
- Modificar `DeferredCompositeCS.hlsl` ou o compute de SSGI para aceitar SRV de depth alternativo.
- Garantir fallback limpo quando SSDM está desabilitado (usar depth original).

## Detalhes técnicos

**Ordem de passes no pipeline deferred (Deferred.cpp):**

```
[Geometry Pass]          ← ExtendedMaterials escreve HeightGBuffer aqui
[Prepass]
  1. ScreenSpaceGI prepass (depth hierarchy, etc.)
  2. SSDM DrawSSDM()          ← NOVO: roda ANTES do SSGI principal
       a. prefilterDepth
       b. displace
       c. temporal
       d. blur
  3. SSGI principal (usa depth refinado do SSDM se disponível)
  4. ... outros efeitos ...
[Deferred Composite]
```

**Integração em Deferred.cpp `PrepassPasses()`:**

```cpp
// SSDM deve rodar antes de SSGI para fornecer depth refinado
auto& ssdm = globals::features::screenSpaceDisplacementMapping;
if (ssdm.loaded)
    ssdm.DrawSSDM();

auto& ssgi = globals::features::screenSpaceGI;
if (ssgi.loaded) {
    // Passar depth refinado se SSDM disponível
    auto refinedDepthSRV = (ssdm.loaded && ssdm.settings.Enabled)
        ? ssdm.GetFinalRefinedDepthSRV()
        : nullptr;
    ssgi.DrawSSGI(refinedDepthSRV);
}
```

**Modificação em ScreenSpaceGI:**

- Adicionar parâmetro opcional `ID3D11ShaderResourceView* refinedDepthSRV = nullptr` em `DrawSSGI()`.
- Se `refinedDepthSRV != nullptr`, bind como `t_additional` no compute shader de GI.
- No shader `gi.cs.hlsl`: se o SRV adicional está bound (verificar via constante bool no CB), usar depth refinado no raymarching de GI em vez do depth raw.

**Alternativa mais simples (recomendada para primeira iteração):**
Em vez de modificar `ScreenSpaceGI`, usar o depth refinado como um replacement do depth buffer na textura de depth que SSGI já lê. Isso requer bind do depth refinado no slot que SSGI usa para depth, o que pode ser feito substituindo o SRV na lista de binds de `DrawSSGI()`.

**`GetFinalRefinedDepthSRV()` em ScreenSpaceDisplacementMapping:**

```cpp
ID3D11ShaderResourceView* GetFinalRefinedDepthSRV()
{
    if (!settings.Enabled || !texFinalRefinedDepth)
        return nullptr;
    return texFinalRefinedDepth->srv.get();
}
```

**Validação de compatibilidade de formato:**
O depth refinado está em `DXGI_FORMAT_R32_FLOAT` (linear depth). Se SSGI espera raw depth (não-linear), adicionar conversão linear→raw no output do blur.cs.hlsl ou criar um passo de conversão separado.

## Critérios de Aceitação

- [ ] SSAO/SSGI mostra sombras de contato mais profundas em superfícies com parallax (visível em pedras, tijolos) quando SSDM está ativo. *(requer in-game)*
- [ ] Desabilitar SSDM reverte SSAO/SSGI para comportamento original sem regressão. *(requer in-game — código: `GetVirtualDepthSRV()` retorna null quando desabilitado → `EnableSSDMDepth=0` → raw depth path)*
- [x] Sem crash quando ScreenSpaceGI está loaded mas SSDM não está — `ssdm.GetVirtualDepthSRV()` retorna null, SSGI recebe null e usa raw depth com `EnableSSDMDepth=0`. *(validado por code review)*
- [x] Sem crash quando SSDM está loaded mas ScreenSpaceGI não está — `ssdm.DrawSSDM()` roda, `ssgi.DrawSSGI()` não é chamado. *(validado por code review)*
- [x] Ordem de passes correta: `ssdm.DrawSSDM()` movido para antes de `ssgi.DrawSSGI()` em `DeferredPasses()`. *(validado por code review)*
- [x] Sem conflitos de registro D3D11 — SSDM faz unbind de todos os SRVs/UAVs antes de retornar; SSGI recomeça com slots limpos. *(validado por code review)*
- [ ] VR: integração funciona para ambos os olhos. *(requer in-game — nota: VR mask pixels (raw=0) terão depth ~infinity em SSDM output, faded out por `GetDepthFade` no SSGI)*

## Arquivos / áreas afetadas

- `src/Deferred.cpp` (adicionar chamada a `DrawSSDM()` na ordem correta; passar depth refinado para SSGI)
- `src/Features/ScreenSpaceDisplacementMapping.h` (adicionar `GetFinalRefinedDepthSRV()`)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (implementar `GetFinalRefinedDepthSRV()`)
- `src/Features/ScreenSpaceGI.h` (adicionar parâmetro opcional em `DrawSSGI()`)
- `src/Features/ScreenSpaceGI.cpp` (usar depth refinado quando fornecido)
- `features/Screen Space GI/Shaders/ScreenSpaceGI/gi.cs.hlsl` (aceitar SRV de depth alternativo opcionalmente)

## Dependências

- TASK-SSDM-005 (texFinalRefinedDepth deve existir)
- TASK-SSDM-006 (pipeline de 4 passes em DrawSSDM() deve estar completo)

## Observações

- Começar com a alternativa simples (substituir SRV de depth no bind de SSGI) antes de modificar o shader de GI. Se o formato de depth for compatível, isso pode ser suficiente.
- SSR (Screen Space Reflections) pode ser integrado na mesma task ou diferida para uma task de polimento — depende da complexidade encontrada.
- Se o overhead de modificar SSGI for muito alto, uma alternativa válida para MVP é simplesmente expor o SRV refinado e deixar outros efeitos consumi-lo em tasks futuras, focando nesta task apenas na integração de pipeline (ordem de passes e exposição do SRV).
- Documentar claramente no código qual slot de input SSDM usa em cada feature downstream para facilitar manutenção futura.
