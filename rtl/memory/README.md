# `memory` — contrato de interface

Blocos do Memory (decisão 17; especificação na wiki, `Memory.md`). Hoje só o
`store_buffer` existe; o load buffer e a memória de dados vêm depois. O
`core` ainda não instancia nenhum deles: o Memory continua sendo uma porta do
`core`, que os testbenches imitam.

## `store_buffer`

Guarda os stores que ainda não gravaram na memória, em ordem de programa.
Cada entrada passa por *livre* → *reservada* (Dispatch) → *finished* (AGU de
store) → *completed* (commit do ROB) → *livre* (gravada na memória). Detalhes
e a tabela de portas: wiki `Memory.md`, "Store buffer: interface do bloco".

### Parâmetros

| Parâmetro | Padrão | Significado |
|---|---|---|
| `W` | 3 | largura do bundle: reservas e commits por ciclo |

`SB_ENTRIES` (12), `SB_PTR_W` e o tipo `sb_ptr_t` vêm do `execute_pkg`. Os
ponteiros contam o índice módulo 12 e têm um bit de volta (`sb_ptr_add`,
`sb_ptr_prev`).

### Portas

| Grupo | Portas |
|---|---|
| Controle | `clk`, `reset`, `flush` |
| Dispatch | `sb_alloc[W]` (entrada); `sb_free`, `sb_tail` (saída) |
| AGU de store | `st_valid`, `st_resp`, `st_data`, `st_op`, `st_idx` (entrada) |
| ROB | `st_commit[W]` (entrada); `lsu_ready` (saída, sempre 1) |
| Memória de dados | `wr_valid`, `wr_addr`, `wr_data`, `wr_strb` (saída); `wr_ready` (entrada) |
| Load buffer | `ret_valid`, `ret_idx` (saída): o store que saiu no ciclo |
| Busca do load | `fw_addr`, `fw_op`, `fw_color` (entrada); `fw_match`, `fw_full`, `fw_data`, `fw_idx` (saída, combinacional) |
| `fence` | `sb_empty` (saída) |

### Garantias

- A AGU de store nunca espera: a reserva no Dispatch garante o lugar.
- Uma resposta com exceção não preenche a entrada; ela fica *reservada*, não
  aparece na busca e é liberada pelo flush do trap.
- O commit só move o ponteiro `cmt`; a escrita na memória sai do `head`, uma
  por ciclo, quando `wr_ready = 1`. O `retire_team` faz commit de no máximo
  um store por ciclo, mas o buffer conta todos os bits de `st_commit`.
- `wr_addr` é alinhado em 8 bytes, `wr_data` já traz os bytes na posição e
  `wr_strb` marca os bytes gravados.
- No flush, as entradas *reservada* e *finished* voltam a *livre* e o `tail`
  recua para o `cmt`. As *completed* ficam e continuam visíveis para os
  loads. Um `st_commit` do mesmo ciclo é aplicado antes do flush.
- A busca considera as entradas *finished* e *completed* do `head` até a cor
  do load e devolve o store mais novo que se sobrepõe a ele (`fw_idx`).
  `fw_full` diz se esse store cobre todos os bytes do load; só então
  `fw_data` serve como dado. Uma cor que já saiu do buffer não seleciona
  nada.

## Teste

`tb/unit/store_buffer_tb.sv` (202 verificações), casos S1 a S12: reset,
reserva de um bundle, execução fora de ordem com escrita em ordem (commit e
escrita no mesmo ciclo), formato da escrita por tamanho e posição, memória
ocupada, flush com *completed* que ficam, commit e flush no mesmo ciclo,
store com exceção, buffer cheio, volta dos ponteiros, busca de forwarding
(cobertura total e parcial, cor antes do primeiro store, entrada reservada
ignorada, *completed* ainda visível) e dois commits no mesmo ciclo. Quatro
mutações do RTL (flush que descarta o commit do mesmo ciclo, busca pelo mais
antigo, cobertura sempre total, cor sem teste de validade) fazem o teste
falhar.
