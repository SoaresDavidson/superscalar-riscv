# `rs_int` e `rs_mem` — contrato de interface

Estações de reserva do estágio Issue. Guardam as instruções aceitas pelo
dispatch até que as duas fontes estejam prontas e a FU esteja livre, e então as
emitem, lendo os operandos do banco físico no mesmo ciclo.

| Módulo | Alimenta | Instruções (`fu_of(op)`) | Entradas (padrão) |
|---|---|---|---|
| `rs_int` | ALU e Branch Unit | `FU_ALU`, `FU_BRANCH` | 8 |
| `rs_mem` | AGU | `FU_AGU` | 4 |

Especificação: [`docs/rs/RS.md`](../../docs/rs/RS.md). Tipos das entradas
(`rs_int_entry_t`, `rs_mem_entry_t`): `rtl/dispatch/dispatch_pkg.sv`. Tipos
compartilhados (`fu_req_t`, `tag_t`, `xlen_t`, `fu_of`):
`rtl/execute/execute_pkg.sv`.

A organização em duas RS e os tamanhos são uma proposta ainda não registrada
em `Decisoes-de-Projeto` (ver Pendências).

## Parâmetros

| Parâmetro | `rs_int` | `rs_mem` | Significado |
|---|---|---|---|
| `W` | 3 | 3 | escritas por ciclo (largura do bundle) |
| `ENTRIES` | 8 | 4 | número de entradas |
| `WB_N` | 3 | 3 | barramentos de write-back: ALU, Branch Unit, load |

Larguras derivadas: `CNT_W = $clog2(ENTRIES + 1)` (contagem de livres, de 0 a
`ENTRIES`), `SLOT_W` (índice de slot) e `IDX_W` (índice de entrada).

## Portas

### Controle

| Porta | Dir. | Significado |
|---|---|---|
| `clk`, `reset` | entrada | `reset` síncrono, ativo-alto: esvazia a RS |
| `flush` | entrada | esvazia a RS na borda; no mesmo ciclo nenhuma requisição sai |

### Dispatch

| Porta | Dir. | Liga em | Significado |
|---|---|---|---|
| `wr[W]` | entrada | `int_wr` / `mem_wr` | o slot `k` traz uma instrução para esta RS |
| `wr_entry[W]` | entrada | `int_entry` / `mem_entry` | a entrada montada de cada slot |
| `free` | saída | `int_free` / `mem_free` | entradas livres no começo do ciclo |

### Barramentos de write-back

| Porta | Dir. | Significado |
|---|---|---|
| `wb_valid[WB_N]` | entrada | há um resultado no barramento `p` |
| `wb_tag[WB_N]` | entrada | tag escrita pelo barramento `p` |

São os mesmos sinais das portas `wb_*` do `PRFRename`, que precisa ser
instanciado com o mesmo `WB_N` (o padrão dele é 1).

`WB_N` conta quem **escreve registrador**. O ROB (`retire_team`) tem outra
contagem, de quem **termina instrução**: 4 portas de resposta, porque a AGU
também responde a ele (é o que fecha um store). Ligação no `core`:

| Origem | Barramento `wb[p]` (RS e `PRFRename`) | Resposta ao ROB |
|---|---|---|
| ALU | 0 | 0 |
| Branch Unit | 1 | 1 |
| AGU | — (não acorda ninguém) | 2, **só stores e exceções** |
| Load (LSU) | 2 | 3 |

O `wb_valid[p]` é `resp_valid && wr_en`: um `beq` responde ao ROB, mas não
anuncia tag. A AGU **não** responde ao ROB por um load sem exceção: o ROB
marcaria o load como terminado antes de o dado voltar, e ele seria efetivado
com o registrador ainda sem valor. O load termina pela porta 3, com o dado.
O `tb/integration/backend_tb.sv` liga tudo assim e falha se a AGU responder
pelos loads.

### FU e portas de leitura do banco

`rs_int` tem dois conjuntos, `alu_*` e `br_*`; `rs_mem` tem um, `agu_*`.

| Porta | Dir. | Significado |
|---|---|---|
| `*_req_valid` | saída | há uma instrução pronta para a FU |
| `*_req_ready` | entrada | a FU aceita; transferência na borda com os dois em 1 |
| `*_req` | saída | `fu_req_t` da instrução selecionada |
| `*_read_tag[2]` | saída | tags das fontes 1 e 2 da instrução selecionada |
| `*_read_valid[2]` | entrada | não usada: sai sempre 1 na emissão (`RS.md`) |
| `*_read_data[2]` | entrada | valores lidos; vão para `src1` e `src2` do `fu_req_t` |

Portas de leitura do `PRFRename` (`READ_N = 6`): 0 e 1 para `alu_*`, 2 e 3 para
`br_*`, 4 e 5 para `agu_*`.

## Comportamento

As entradas guardam só tags (decisão 16 da wiki). Todo ciclo:

| Etapa | Regra |
|---|---|
| Alocação | a k-ésima instrução com `wr = 1` ocupa a k-ésima entrada livre no começo do ciclo, contando da entrada 0 |
| Wakeup | uma fonte com `ready = 0` fica pronta na borda em que um barramento traz `wb_valid = 1` e a sua tag; vale também para a entrada escrita no mesmo ciclo |
| Seleção | por FU, a entrada pronta (`busy` e as duas fontes prontas) de menor índice; os bits de pronto são os registrados, então quem acorda num ciclo só sai no seguinte |
| Emissão | as tags da entrada selecionada vão para `*_read_tag`; o `fu_req_t` sai no mesmo ciclo com `read_data`; na transferência a entrada fica livre |
| Livres | `free` conta `busy = 0` no começo do ciclo; a entrada liberada por uma emissão aparece no ciclo seguinte |
| Reset e flush | esvaziam todas as entradas, inclusive uma escrita do mesmo ciclo |

Campos do `fu_req_t`:

| Campo | `rs_int` | `rs_mem` |
|---|---|---|
| `src1`, `src2` | `read_data[0]`, `read_data[1]` | idem (store: base e dado; load: base e `x0`) |
| `op`, `imm`, `dst_tag`, `wr_en`, `age` | copiados da entrada | copiados da entrada |
| `use_imm`, `pc`, `pred_taken`, `pred_target` | copiados da entrada | 0 (a entrada não tem) |

Garantias para os vizinhos:

- No máximo uma requisição por FU por ciclo; uma requisição parada por
  `req_ready = 0` se mantém igual até ser aceita, e sai uma única vez.
- Com `flush = 1`, nenhuma requisição sai naquele ciclo.
- O dispatch nunca manda mais instruções do que `free` (`int_free >= n_int`,
  `mem_free >= n_mem`); a RS não verifica isso.

## Pendências

Ver `docs/rs/RS.md`, "Pontos em aberto". As que mudam esta interface:

- **Organização e tamanhos** (item 0): proposta enviada ao grupo; falta o
  registro em `Decisoes-de-Projeto`.
- **Seleção pela mais antiga** (item 1): o `age` já chega do ROB pelo
  dispatch; a seleção continua pelo índice.
- **Flush seletivo** (item 3): exigiria uma entrada `flush_age`.
- **Ordem na RS MEM** (item 4): hoje loads e stores saem pelo menor índice,
  sem respeitar a ordem do programa.
- **`pred_taken` / `pred_target`**: chegam em zero até o Fetch prever desvios.

## Testes

| Testbench | Casos | Verificações |
|---|---|---|
| `tb/unit/rs_int_tb.sv` | R1 a R13 | 71 |
| `tb/unit/rs_mem_tb.sv` | M1 a M13 | 68 |
| `tb/integration/backend_tb.sv` | programa de 42 instruções do Decode ao commit, com ALU, AGU, Rename e ROB reais | fluxo de commit inteiro |

Os dois cobrem reset, escrita e emissão com conferência dos campos, RS cheia,
tempo do wakeup, anúncio no mesmo ciclo da escrita, seleção pelo menor índice,
back-pressure, `free` contado no começo do ciclo, alocação com buracos, flush
(com escrita e requisição parada no mesmo ciclo) e reuso de tag depois do
flush. O `rs_int_tb` cobre também duas fontes acordadas por barramentos
diferentes e ALU e Branch Unit emitindo no mesmo ciclo; o `rs_mem_tb`, os
campos de load e de store e o store esperando o dado.
