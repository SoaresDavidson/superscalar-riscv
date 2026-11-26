# `core` — topo do processador

Liga todos os blocos que já existem. O que ainda não existe vira porta do
`core`: memória de instruções, Branch Unit e Memory. Um testbench faz o papel
deles, e o RTL definitivo entra no lugar quando ficar pronto.

```
fetch -> PipeFifo -> decode -> dispatch -> PRFRename -> rs_int -> alu
                                                     -> rs_int -> (porta da Branch Unit)
                                                     -> rs_mem -> agu -> (porta do Memory)
                                        -> retire_team (ROB) -> commit -> PRFRename
alu / Branch Unit / agu / Memory -> completion -> PRFRename, RS, ROB
```

Tipos: `rtl/execute/execute_pkg.sv` e `rtl/dispatch/dispatch_pkg.sv`.

## Parâmetros

| Parâmetro | Padrão | Significado |
|---|---|---|
| `W` | 3 | largura; o `retire_team` exige 3 |
| `RESET_PC` | `0` | PC depois do reset (repassado ao `fetch`; valor ainda não decidido) |
| `FQ_DEPTH` | 4 | bundles no `PipeFifo` entre Fetch e Decode |
| `DEEP2` | 0 | variante do `retire_team` |

Contagens internas fixas: 3 barramentos de write-back, 6 portas de leitura do
PRF (0-1 ALU, 2-3 Branch Unit, 4-5 AGU) e 4 portas de resposta do ROB.

## Portas

### Memória de instruções

| Porta | Dir. | Significado |
|---|---|---|
| `imem_addr[W]` | saída | endereço de cada slot (o `imem_addr` do `fetch`) |
| `imem_rdata[W]` | entrada | instrução do endereço do ciclo anterior (memória síncrona) |

### Branch Unit

| Porta | Dir. | Significado |
|---|---|---|
| `br_req_valid`, `br_req` | saída | pedido da `rs_int`, com os operandos já lidos do PRF |
| `br_req_ready` | entrada | a Branch Unit aceita |
| `br_resp_valid`, `br_resp` | entrada | resposta; vai ao `completion` (write-back 1, porta 1 do ROB) |
| `br_resp_ready` | saída | sempre 1 |
| `br_redirect` | entrada | `redirect_t` direto na entrada `redirect` do `retire_team` |

Sem Branch Unit, ligue `br_req_ready = 0`: um desvio fica parado na RS INT.

### Memory

| Porta | Dir. | Significado |
|---|---|---|
| `agu_resp_valid`, `agu_resp` | saída | resposta da AGU: endereço em `result`, `dst_tag`, `wr_en`, `age` |
| `agu_is_load` | saída | a resposta é de um load (`resp_is_load` da `agu`) |
| `agu_store_data` | saída | dado do store (`src2`), válido com `agu_resp_valid` |
| `agu_op` | saída | `op` do acesso: tamanho, sinal e direção |
| `agu_lsq_idx` | saída | entrada no store buffer ou no load buffer; 0 até o Dispatch reservar as entradas |
| `agu_color` | saída | cor do load; 0 até o Dispatch reservar |
| `lsu_resp_valid`, `lsu_resp` | entrada | dado do load, já estendido, com os metadados da resposta da AGU |
| `lsu_resp_ready` | saída | sempre 1 |
| `st_commit[W]`, `ld_commit[W]` | saída | stores e loads que o ROB fez commit neste ciclo |
| `lsu_ready` | entrada | entrada `lsu_ready` do `retire_team` |
| `flush` | saída | flush total; o Memory descarta as leituras em voo |

### Observação

| Porta | Dir. | Significado |
|---|---|---|
| `commit_valid[W]`, `commit_rd[W]`, `commit_tag[W]` | saída | commits de registrador, em ordem de programa |
| `rob_empty` | saída | ROB vazio |

## Comportamento

- **Fetch -> Decode** passa por um `PipeFifo`, com o bundle empacotado como
  `{slot_valid, pc, inst}`. A FIFO esvazia no flush do ROB e no redirect do
  Decode (`JAL`), porque os bundles atrás do `JAL` estão no caminho errado.
- **Flush** é o do `retire_team` e é total: Decode, Dispatch, rename, as duas
  RS e a FIFO esvaziam, e o Fetch segue o `be_redirect_pc`. As FUs só têm
  flush seletivo por idade, então o `core` bloqueia pedidos novos durante o
  flush (`req_valid && !flush`) e liga `flush_age = 0`. Nenhum pedido entra
  numa FU no ciclo do flush, o `completion` descarta o que sai dela nesse
  ciclo, e o registrador de saída esvazia na borda.
- **CSR**: sem instruções de CSR executando ainda. `mtvec_wr_*` e `csr_rd_*`
  do `retire_team` estão desligados, e `rob_sys_kind` é 0 (o `uop_t` não
  carrega o tipo de instrução de sistema).

## Pendências

- **Branch Unit**: não existe. Com ela, o flush seletivo por `redirect.age`
  passa a valer para as FUs; as RS só têm flush total (Issue, item 3).
- **Memory**: especificado na wiki (decisão 17), sem RTL. A porta já leva o
  dado do store, o `op` e o índice e a cor da entrada; falta o Dispatch
  reservar as entradas (`sb_*`/`lb_*`), então `agu_lsq_idx` e `agu_color`
  saem em 0. O `core_tb` e o `core_isa_tb` tiram o tamanho do acesso de
  `agu_op`.
- **`out_slot_kill`** do Decode fica desligado: os slots mortos já chegam com
  `uop.valid = 0` (rtl/decode/README.md).

## Teste

```sh
make test T=core   # tb/integration/core_tb.sv, DEEP2 = 0 e 1
```

O programa do `backend_tb`, agora buscado da memória pelo Fetch, seguido de um
`LD` desalinhado. A exceção faz o ROB dar flush e mandar o Fetch para o
`mtvec`. As instruções atrás do `LD` estão em voo e não podem fazer commit; o
handler lê `x20`, que uma delas sobrescreveu de forma especulativa, e isso
confere que o rename voltou ao mapeamento do commit e reusou as tags liberadas.
O testbench compara o fluxo de commit (registrador e valor) com um modelo de
referência e confere loads e stores no commit, exatamente um flush para o
`mtvec`, nenhum commit depois do handler e o Fetch seguindo adiante.

### Suíte de ISA

```sh
make test-isa      # tb/isa/core_isa_tb.sv, DEEP2 = 0 e 1
```

Roda 25 programas curtos, um por recurso do RV64I, cada um a partir do reset,
e compara com um modelo de referência RV64I escrito no próprio testbench:
fluxo de commit (registrador e valor), nenhum commit depois do fim do programa
ou de um trap, contagem de loads e stores e conteúdo final da memória de
dados. Um programa que falha não interrompe os outros: o relatório no fim
lista todos, com o motivo de cada falha. Um programa que fica 400 ciclos sem
commit é dado como travado, e a mensagem aponta a primeira instrução depois
do último commit.

A suíte falha de propósito enquanto faltar RTL, por isso fica fora do
`make test` e do CI. Hoje passam 15 de 25. As falhas são:

| Programas | Motivo |
|---|---|
| `branch_not_taken`, `branch_taken`, `branch_loop`, `jalr`, `prog_sum_array`, `prog_memcpy` | sem Branch Unit, o primeiro desvio fica parado na RS INT |
| `store_then_load`, `store_memory` | o modelo do Memory no testbench não tem store queue: os stores não chegam à memória de dados |
| `ecall`, `ebreak` | o ROB faz commit de `ECALL`/`EBREAK` como instrução comum (`rob_sys_kind` = 0) |

Para `ECALL` e `EBREAK`, a suíte só exige o que o RV64I fixa: nem a instrução
nem as seguintes fazem commit. Para onde o core vai depois do trap (handler ou
parada) depende da decisão 10, que está em aberto, e não é conferido.

