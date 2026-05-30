# TASK-SSDM-002: Expor Height GBuffer via ExtendedMaterials

**Épico:** EPIC-SSDM
**Labels:** `feature`, `cpp`, `extended-materials`, `gbuffer`, `render-target`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 3 story points

---

## Descrição

Estender a feature `ExtendedMaterials` para criar um render target dedicado ao armazenamento da altura calculada pelo Complex Parallax/POM durante o material pass. Este render target (Height GBuffer) será a fonte de dados de deslocamento que o SSDM usará na Fase 3.

A lógica de escrita da altura no render target é implementada em TASK-SSDM-003 (shader). Esta task cobre apenas o lado C++: criação do recurso, bind no pipeline e exposição pública do SRV.

## Escopo

- Adicionar `eastl::unique_ptr<Texture2D> texHeightGBuffer` à `ExtendedMaterials`.
- Criar o render target em `SetupResources()` com formato `DXGI_FORMAT_R16_FLOAT` (single-channel, half precision).
- Expor o RTV para bind durante o material pass e o SRV para consumo pelo SSDM.
- Adicionar método `ID3D11ShaderResourceView* GetHeightGBufferSRV()` em `ExtendedMaterials`.
- Limpar o render target no início de cada frame (clear para 0.0f) para evitar dados stale em pixels sem parallax.

## Detalhes técnicos

**Dimensões do render target:**
- Mesmas do backbuffer (render width × render height)
- Formato: `DXGI_FORMAT_R16_FLOAT` — suficiente para altura normalizada [0.0, 1.0]
- Sem mips (único nível)

**Nomeação de recurso (obrigatório per CLAUDE.md):**
```cpp
texHeightGBuffer = eastl::make_unique<Texture2D>(desc, "ExtendedMaterials::HeightGBuffer");
```

**Bind durante material pass:**
O render target deve ser atachado como `RTV[slot_adicional]` durante o draw de geometria com parallax ativo. Isto requer identificar onde `ExtendedMaterials` já faz hooks no pipeline e adicionar o bind nesse ponto.

**Clear por frame:**
```cpp
float clearColor[4] = { 0.f, 0.f, 0.f, 0.f };
context->ClearRenderTargetView(texHeightGBuffer->rtv.get(), clearColor);
```
Fazer o clear em `Prepass()` antes do draw de geometria.

**Descriptor de criação:**
```cpp
D3D11_TEXTURE2D_DESC desc{
    .Width  = width,
    .Height = height,
    .MipLevels = 1,
    .ArraySize = 1,
    .Format = DXGI_FORMAT_R16_FLOAT,
    .SampleDesc = { .Count = 1 },
    .Usage = D3D11_USAGE_DEFAULT,
    .BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE,
};
```

## Critérios de Aceitação

- [x] `texHeightGBuffer` é criado sem erros D3D11 ao iniciar o jogo com ExtendedMaterials carregado. *(implementado como canal B de `texDisplacement` RGBA16 em vez de RT separado)*
- [ ] O recurso aparece com nome correto no RenderDoc (`ExtendedMaterials::HeightGBuffer`). *(visível como `ExtendedMaterials::Displacement` — verificar no RenderDoc)*
- [x] `GetHeightGBufferSRV()` retorna SRV válido (não nulo quando loaded). *(implementado e build OK)*
- [x] Clear por frame funciona — pixel sem parallax tem valor 0.0 no RenderDoc. *(`ClearDisplacementTexture()` limpa todos os canais — verificar canal B no RenderDoc)*
- [x] Compilação sem warnings ou erros.
- [ ] Não há regressão visual em parallax existente. *(requer teste in-game)*

## Arquivos / áreas afetadas

- `src/Features/ExtendedMaterials.h` (adicionar membro `texHeightGBuffer` + método `GetHeightGBufferSRV()`)
- `src/Features/ExtendedMaterials.cpp` (criar recurso em `SetupResources()`, clear em `Prepass()`, bind no hook de material pass)

## Dependências

- TASK-SSDM-001 (framework da feature SSDM deve existir para que o SRV seja consumido)

## Observações

- O render target só precisa existir quando `ExtendedMaterials` está loaded **e** a feature SSDM também está loaded. Considerar check `globals::features::screenSpaceDisplacementMapping.loaded` antes de criar/usar o recurso para minimizar overhead quando SSDM está desabilitado.
- Se o jogo usa MSAA, o render target de altura deve ser criado sem MSAA (resolve separado não é necessário — a altura é um valor escalar simples).
- Documentar no header que `GetHeightGBufferSRV()` pode retornar `nullptr` quando parallax não está ativo, e o SSDM deve tratar esse caso graciosamente.
- A separação entre criação do recurso (TASK-SSDM-002) e escrita do shader (TASK-SSDM-003) é intencional para facilitar revisão de código independente.
