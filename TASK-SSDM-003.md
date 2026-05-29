# TASK-SSDM-003: Escrever Altura Parallax no Height GBuffer via Lighting.hlsl

**Épico:** EPIC-SSDM
**Labels:** `shader`, `hlsl`, `extended-materials`, `gbuffer`, `parallax`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 3 story points

---

## Descrição

Modificar o shader de material (`package/Shaders/Lighting.hlsl`) para escrever o valor de altura calculado durante o Complex Parallax/POM no render target `HeightGBuffer` criado em TASK-SSDM-002. O valor de altura deve representar a profundidade de deslocamento em espaço tangente (0.0 = sem deslocamento, 1.0 = deslocamento máximo), normalizado pela escala de parallax configurada.

## Escopo

- Identificar onde `Lighting.hlsl` calcula ou acessa a altura de parallax (seção `#ifdef COMPLEX_PARALLAX`).
- Adicionar output de altura ao pixel shader sob guard `#if defined(COMPLEX_PARALLAX) && defined(SSDM_HEIGHT_OUTPUT)`.
- Registrar o RTV adicional no bind correto (deve corresponder à posição do render target atachado pelo C++ em TASK-SSDM-002).
- Garantir que pixels sem parallax (ou com parallax desabilitado) escrevem 0.0 no canal.
- Validar com hlslkit que não há warnings X4000 (output sem uso) ou conflitos de registro.

## Detalhes técnicos

**Localização aproximada no Lighting.hlsl:**
Procurar pela macro `COMPLEX_PARALLAX` ou `PARALLAX` e identificar onde `parallaxOffset` ou `heightMap` é amostrado. O valor de altura bruto (antes de escalar para UV offset) é o que deve ser escrito.

**Adição ao pixel shader output struct:**
```hlsl
#if defined(COMPLEX_PARALLAX) && defined(SSDM_HEIGHT_OUTPUT)
    float parallaxHeight : SV_Target[N];  // N = slot do HeightGBuffer
#endif
```

**Escrita no output:**
```hlsl
#if defined(COMPLEX_PARALLAX) && defined(SSDM_HEIGHT_OUTPUT)
    psout.parallaxHeight = heightSample;  // valor raw [0.0, 1.0] do height map
#endif
```

**Guard de compilação:**
A define `SSDM_HEIGHT_OUTPUT` deve ser adicionada pelo `ShaderCache` apenas quando SSDM está loaded. Isso garante zero overhead de shader quando SSDM está desabilitado. Verificar como `ExtendedMaterials` já injeta defines via `GetShaderDefineName()` e replicar o padrão em `ScreenSpaceDisplacementMapping`.

**Slot do render target:**
Definir constante em `src/Features/ScreenSpaceDisplacementMapping.h`:
```cpp
static constexpr uint32_t kHeightGBufferRTVSlot = 7;  // Verificar slots livres
```
E usar o mesmo valor tanto no C++ (bind do RTV) quanto no shader (`SV_Target7`).

## Critérios de Aceitação

- [ ] Compilação de `Lighting.hlsl` não gera erros ou warnings novos (validar com hlslkit).
- [ ] No RenderDoc, pixels com parallax ativo mostram valor > 0.0 no `HeightGBuffer`.
- [ ] Pixels sem parallax (superfícies planas) mostram 0.0 no `HeightGBuffer`.
- [ ] Performance do material pass não é afetada mensurável quando SSDM está desabilitado (define guard funciona).
- [ ] VR: ambos os olhos escrevem no `HeightGBuffer` corretamente.
- [ ] Sem regressão visual em qualquer shader existente.

## Arquivos / áreas afetadas

- `package/Shaders/Lighting.hlsl` (adicionar output de altura sob define guard)
- `src/Features/ScreenSpaceDisplacementMapping.h` (adicionar `GetShaderDefineName()` override + constante do slot)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (implementar `HasShaderDefine()` para Lighting shader type)

## Dependências

- TASK-SSDM-001 (feature C++ deve existir para implementar `GetShaderDefineName()`)
- TASK-SSDM-002 (render target HeightGBuffer deve existir para ser escrito)

## Observações

- Inspecionar `src/Features/ExtendedMaterials.cpp` para ver como `HasShaderDefine()` é implementado — SSDM deve seguir o mesmo padrão para injetar `SSDM_HEIGHT_OUTPUT` apenas nos shader types relevantes (`Lighting`).
- Se `Lighting.hlsl` já tem um número alto de render targets ativos, verificar se há slots disponíveis. Alternativamente, empacotar a altura em um canal alfa não utilizado de um RTV existente (ex: canal A de MASKS ou MASKS2).
- Executar `cmake --build ./build/ALL --target prepare_shaders` e então `hlslkit-compile` para validar antes de considerar a task concluída.
- O valor de altura deve ser não-escalado (raw [0,1]) — a escala de parallax é aplicada no SSDM compute shader, não aqui, para manter flexibilidade.
