# TASK-SSDM-001: Esqueleto C++ da Feature SSDM e Registro no Framework

**Épico:** EPIC-SSDM
**Labels:** `feature`, `cpp`, `framework`, `registration`
**Milestone:** v1.0.0-ssdm
**Estimativa:** 2 story points

---

## Descrição

Criar o esqueleto completo da feature `ScreenSpaceDisplacementMapping` em C++, seguindo o padrão estabelecido pelas features existentes (especialmente `ScreenSpaceGI`). Registrar a feature no framework de globals, feature list e deferred pipeline para que ela exista como uma feature válida mesmo antes de ter shaders funcionais.

## Escopo

- Criar `src/Features/ScreenSpaceDisplacementMapping.h` com struct da feature herdando de `Feature`.
- Criar `src/Features/ScreenSpaceDisplacementMapping.cpp` com implementação stub dos métodos obrigatórios.
- Adicionar forward declaration e `extern` em `src/Globals.h`.
- Adicionar instância em `src/Globals.cpp`.
- Adicionar entrada no `GetFeatureList()` em `src/Feature.cpp`.
- Criar arquivo `.ini` de metadados da feature.
- Criar hook stub em `src/Deferred.cpp` para futura injeção do compute pass.

## Detalhes técnicos

**`ScreenSpaceDisplacementMapping.h`** deve conter:
- Herança de `Feature`
- Struct `Settings` com `alignas(16)` contendo todos os parâmetros (ver TASK-SSDM-008)
- Membros `eastl::unique_ptr<Texture2D>` para as texturas de output (pelo menos `texRefinedDepth[2]`)
- Membro `eastl::unique_ptr<ConstantBuffer> ssdmCB`
- Declarações dos compute shaders (ao menos `csDisplace`)
- Índice de ping-pong `uint outputIdx = 0`
- Método público `void DrawSSDM()` a ser chamado pelo Deferred
- Método público `ID3D11ShaderResourceView* GetRefinedDepthSRV()` para downstream effects
- Override de `SupportsVR()` retornando `true`
- Override de `GetCategory()` retornando `FeatureCategories::kMaterials`

**`src/Globals.h`** — adicionar antes do namespace `features`:
```cpp
struct ScreenSpaceDisplacementMapping;
```
E dentro do `namespace globals::features`:
```cpp
extern ScreenSpaceDisplacementMapping screenSpaceDisplacementMapping;
```

**`src/Feature.cpp`** — adicionar ao vetor de `GetFeatureList()` após `extendedMaterials`.

**`.ini` file** (`features/Screen-Space Displacement Mapping/Shaders/Features/ScreenSpaceDisplacementMapping.ini`):
```ini
[Info]
Version = 0-1-0
```

**`src/Deferred.cpp`** — adicionar ao final de `PrepassPasses()`:
```cpp
auto& ssdm = globals::features::screenSpaceDisplacementMapping;
if (ssdm.loaded)
    ssdm.DrawSSDM();
```

## Critérios de Aceitação

- [ ] Projeto compila sem erros com os novos arquivos.
- [ ] Feature aparece no menu in-game do Community Shaders na categoria Materials.
- [ ] Feature pode ser habilitada/desabilitada via menu sem crash.
- [ ] `GetFeatureList()` inclui a nova entry em posição adequada (após `extendedMaterials`).
- [ ] Arquivo `.ini` é detectado pelo sistema de versioning (build target `generate_shader_configs` não falha).
- [ ] `DrawSSDM()` stub não causa crash quando chamado no deferred pipeline.

## Arquivos / áreas afetadas

- `src/Features/ScreenSpaceDisplacementMapping.h` (**novo**)
- `src/Features/ScreenSpaceDisplacementMapping.cpp` (**novo**)
- `features/Screen-Space Displacement Mapping/Shaders/Features/ScreenSpaceDisplacementMapping.ini` (**novo**)
- `src/Globals.h` (adicionar forward declaration + extern)
- `src/Globals.cpp` (adicionar instância)
- `src/Feature.cpp` (adicionar ao GetFeatureList)
- `src/Deferred.cpp` (adicionar hook stub)

## Dependências

Nenhuma. Esta é a task fundacional do EPIC-SSDM.

## Observações

- O build autodiscover (`cmake/AddCXXFiles.cmake`) usa `GLOB_RECURSE` em `src/*.cpp` e `src/*.h`, então não é necessário editar `CMakeLists.txt` para os arquivos C++.
- Manter `SetupResources()` com corpo vazio nesta fase — recursos GPU são criados em TASK-SSDM-005.
- Seguir o padrão de `ScreenSpaceGI` como referência primária para a estrutura do header.
- Não incluir `#include "Features/ScreenSpaceDisplacementMapping.h"` diretamente em `Deferred.cpp` — usar `src/Globals.h` que já inclui os headers das features.
