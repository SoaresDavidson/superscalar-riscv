# `dispatch` — contrato de interface

Recebe do Decode um bundle de até `W` instruções e, tudo ou nada (decisão 15),
reserva para cada slot válido uma entrada no ROB, uma tag no Rename (se o slot
escreve registrador) e uma entrada numa estação de reserva. É puramente
combinacional: a decisão e as entradas montadas saem no mesmo ciclo, e as
escritas acontecem nos vizinhos, na borda do relógio.

Especificação: [`docs/dispatch/Dispatch.md`](../../docs/dispatch/Dispatch.md).
Tipos das entradas: [`dispatch_pkg.sv`](dispatch_pkg.sv). Tipos compartilhados
(`uop_t`, `exec_op_t`, `fu_of`, `tag_t`, `xlen_t`): `rtl/execute/execute_pkg.sv`.

## Parâmetros

| Parâmetro | Padrão | Significado |
|---|---|---|
| `W` | 3 | largura do bundle (decisão 2) |
| `ROB_ENTRIES` | 48 | tamanho do ROB (`retire_team`: 16 linhas x 3 vias); só define a largura de `rob_free` |
| `RS_INT_ENTRIES` | 8 | entradas da RS INT |
| `RS_MEM_ENTRIES` | 4 | entradas da RS MEM |

Larguras derivadas: `*_CNT_W = $clog2(N + 1)` (contagem de livres, de 0 a
`N`). `SB_CNT_W` e `LB_CNT_W` seguem `SB_ENTRIES` e `LB_ENTRIES` do
`execute_pkg`. `XLEN` e `TAG_W` vêm
do `execute_pkg`, não são parâmetros.

## Portas

### Controle

| Porta | Dir. | Significado |
|---|---|---|
| `clk`, `reset` | entrada | não usadas: o bloco é combinacional |
| `flush` | entrada | com 1, nada é aceito neste ciclo |

### Decode

| Porta | Dir. | Significado |
|---|---|---|
| `dec_valid` | entrada | `out_valid` do Decode: há um bundle |
| `dec_uop[W]` | entrada | um `uop_t` por slot |
| `dec_ready` | saída | `out_ready` do Decode: `rob_ok && rs_ok && ren_dispatch_ready` |

As máscaras de dependência do Decode (`out_dep_rs1`, `out_dep_rs2`,
`out_dep_rd`) **não** passam pelo dispatch: vão direto ao `PRFRename`.

As RS guardam só tags (decisão 16 da wiki): o dispatch recebe do
`PRFRename` só tags e bits de pronto, e o `PRFRename` não tem mais saídas de
valor para o dispatch. Os valores são lidos na emissão, pelas portas
`read_tag -> read_data` (ver `docs/rs/RS.md`).

### Rename (`PRFRename`)

| Porta | Dir. | Liga em | Significado |
|---|---|---|---|
| `ren_dispatch_valid` | saída | `dispatch_valid` | `dec_valid && !flush` |
| `ren_slot_valid[W]` | saída | `slot_valid` | slot com instrução |
| `ren_rs1[W]`, `ren_rs2[W]` | saída | `rs1`, `rs2` | registrador da fonte, ou 0 quando `rs*_valid = 0` |
| `ren_rd[W]` | saída | `rd` | registrador de destino |
| `ren_writes_rd[W]` | saída | `writes_rd` | `slot_valid && has_dest` |
| `ren_rob_ready` | saída | `rob_ready` | `rob_ok`: o ROB cabe o bundle |
| `ren_rs_ready` | saída | `rs_ready` | `rs_ok`: as duas RS cabem o bundle |
| `ren_dispatch_ready` | entrada | `dispatch_ready` | há tags para todos os `writes_rd` |
| `ren_src_ready[W][2]` | entrada | `src_ready` | `[0]` fonte 1, `[1]` fonte 2 |
| `ren_src1_tag`, `ren_src2_tag` | entrada | idem | tags das fontes |
| `ren_dst_tag[W]`, `ren_old_tag[W]` | entrada | idem | tag nova e tag anterior do destino |

O Rename só aloca tags com `rob_ready && rs_ready`, ou seja, só quando o bundle
realmente entra: nenhuma tag vaza quando o ROB ou uma RS está cheio. As portas
`rob_ready` e `rs_ready` existem no `PRFRename` do branch `davi#rename`.

### ROB

| Porta | Dir. | Significado |
|---|---|---|
| `rob_free` | entrada | entradas livres; o `retire_team` dá `W` (linha livre) ou 0 |
| `rob_age[W]` | entrada | `age` da entrada que o slot `k` ocupa; vai para o campo `age` das RS |
| `rob_alloc[W]` | saída | o slot `k` ocupa a via `k` da linha alocada |
| `rob_entry[W]` | saída | `rob_entry_t` do slot: `pc`, `rd`, `has_dest`, `dst_tag`, `old_tag`, `done`, `illegal`, `serializing` |
| `rob_uop[W]` | saída | o `uop_t` do bundle, repetido; o `retire_team` lê o `op` para separar load de store |

Ligação com o `retire_team` (`rtl/retire/`): portas de mesmo nome. A entrada
`rob_sys_kind` do `retire_team` ainda não tem quem a produza (ver
pendências); no `core`, fica em 0 até a decisão. O ROB guarda um `pc` por
linha, o do slot 0, e supõe slots consecutivos (`pc + 4`, `pc + 8`).

### Estações de reserva

| Porta | Dir. | Significado |
|---|---|---|
| `int_free`, `mem_free` | entrada | entradas livres em cada RS |
| `int_wr[W]`, `mem_wr[W]` | saída | o slot `k` vai para aquela RS |
| `int_entry[W]` | saída | `rs_int_entry_t` do slot |
| `mem_entry[W]` | saída | `rs_mem_entry_t` do slot |

A RS recebe uma entrada montada por slot e grava as dos slots com o bit de
escrita em 1, escolhendo ela mesma a posição livre. A entrada é montada para
todos os slots; só o bit de escrita diz se ela vale.

### Store buffer e load buffer (decisão 17)

| Porta | Dir. | Significado |
|---|---|---|
| `sb_free`, `lb_free` | entrada | entradas livres em cada buffer |
| `sb_tail`, `lb_tail` | entrada | próxima entrada a reservar, com o bit de volta (`sb_ptr_t`, `lb_ptr_t`) |
| `sb_alloc[W]`, `lb_alloc[W]` | saída | o slot `k` reserva uma entrada naquele buffer |

O índice de cada slot é a cauda mais o número de stores (ou loads) nos slots
anteriores, módulo `SB_ENTRIES` com o bit de volta (`sb_ptr_add`,
`lb_ptr_add` no `execute_pkg`). Vai em `lsq_idx` da entrada da RS MEM. A cor
de um load é a entrada anterior à posição dele no store buffer
(`sb_ptr_prev`): o último store alocado antes dele, mesmo no próprio bundle.

## Comportamento

Roteamento por `fu_of(op)` (Execute: uma FU de cada tipo):

| `fu_of(op)` | RS | `rob_entry.done` |
|---|---|---|
| `FU_ALU` | INT (ALU) | 0 |
| `FU_BRANCH` | INT (Branch Unit) | 0 |
| `FU_AGU` | MEM | 0 |
| `FU_NONE` (ilegal ou sistema) | nenhuma | 1: nenhuma FU vai responder; o Retirement trata |

Aceite:

```
rob_ok   = rob_free >= n_rob
rs_ok    = int_free >= n_int && mem_free >= n_mem
lsq_ok   = sb_free >= n_st && lb_free >= n_ld
space_ok = rob_ok && rs_ok && lsq_ok
accept   = dec_valid && dec_ready && !flush
ren_rs_ready = rs_ok && lsq_ok
```

`n_rob`, `n_int`, `n_mem`, `n_st` e `n_ld` contam os slots válidos, os que
vão para a RS INT, para a RS MEM, os stores e os loads. `rob_alloc`, `int_wr`,
`mem_wr`, `sb_alloc` e `lb_alloc` só ligam com `accept = 1`. O `lsq_ok` entra
no `ren_rs_ready`: sem ele, um buffer cheio recusaria o bundle depois de o
Rename já ter alocado as tags, e elas vazariam.

Garantias para os vizinhos:

- Um slot com `valid = 0` não pede nada, qualquer que seja o `op` que carregue.
- Uma fonte inválida vai ao Rename como `x0`, nunca com o lixo do campo `rs*`.
- Com `flush = 1`, nada é alocado no ROB, nas RS nem no Rename.

## Pendências

Ver `docs/dispatch/Dispatch.md`, "Pontos em aberto". As que mudam esta
interface:

- **`rob_sys_kind`** (item 8): o tipo da instrução de sistema que o
  `retire_team` pede não existe no `uop_t`.
- **`pred_taken` / `pred_target`** (item 5) saem em zero: o `uop_t` não traz
  a predição.

## Teste

`tb/unit/dispatch_tb.sv`, com `W = 3` (149 verificações):

- **T1 a T5, roteamento:** cada tipo de instrução em posições diferentes,
  `FU_NONE`, três instruções na mesma RS e slots inválidos com `op` de lixo.
- **A1 a A8, aceite** (dirigido por tabela, `accept_case`): falta de ROB, de
  RS INT, de RS MEM ou de tags; encaixe exato; Decode sem bundle; flush.
- **C1 a C4, conteúdo:** consultas ao Rename (`x0` e lixo em `rs2`), campos
  das entradas da RS INT e da RS MEM (com o `age` de cada slot), da entrada do
  ROB e do `rob_uop`.
- **L1 a L7, reserva nos buffers:** máscaras, índice e cor por slot, volta do
  índice (12 no store buffer, 16 no load buffer), cor através da volta,
  buffer cheio sem vazar tag, slots inválidos que não contam e flush.
