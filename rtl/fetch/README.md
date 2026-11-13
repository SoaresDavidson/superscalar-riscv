# `fetch` — contrato de interface

Primeiro estágio do pipeline. A cada ciclo, lê da memória de instruções um
bundle de `WIDTH` instruções consecutivas (PC, PC+4, PC+8 com `WIDTH = 3`),
entrega ao Decode com o PC de cada uma e escolhe o PC do ciclo seguinte. O único
estado é o registrador do PC; todo o resto é combinacional.

**Estado: v1.** Busca sequencial, stall, redirect do Decode (`JAL`) e do back
end. Não prevê desvios: todo desvio condicional é buscado como não tomado.

Especificação: [`docs/fetch/Fetch.md`](../../docs/fetch/Fetch.md). Quando este
arquivo e a especificação discordarem, vale a especificação e este arquivo está
desatualizado. Tipos compartilhados (`xlen_t`, `XLEN`):
`rtl/execute/execute_pkg.sv`.

## Parâmetros

| Parâmetro | Padrão | Significado |
|---|---|---|
| `WIDTH` | 3 | instruções por ciclo (decisão 2); nunca um 3 literal no RTL |
| `RESET_PC` | `0` | PC depois do reset; valor ainda não decidido pelo grupo |

`XLEN` vem do `execute_pkg`, como no Decode, e não é parâmetro: o PC é `xlen_t`
lá, e um `XLEN` próprio do módulo poderia divergir dele sem erro. A instrução
tem sempre 32 bits (decisão 1: RV64I, sem extensão C).

## Portas

### Controle

| Porta | Dir. | Significado |
|---|---|---|
| `clk` | entrada | relógio |
| `reset` | entrada | síncrono, ativo em alto. PC vai para `RESET_PC`; `out_valid = 0` enquanto estiver em 1 |

### Memória de instruções

| Porta | Dir. | Significado |
|---|---|---|
| `imem_addr[WIDTH]` | saída | endereço de cada slot: `pc + 4k` |
| `imem_rdata[WIDTH]` | entrada | instrução de cada endereço, de 32 bits, **no mesmo ciclo** (memória combinacional na v1) |

### Decode

As saídas têm os mesmos nomes das entradas `in_*` do Decode e ligam direto.

| Porta | Dir. | Liga em | Significado |
|---|---|---|---|
| `out_valid` | saída | `in_valid` | há um bundle. Vai a 0 no reset e no ciclo de qualquer redirect |
| `out_ready` | entrada | `in_ready` | o Decode aceita. A transferência acontece na borda em que `out_valid` e `out_ready` estão em 1 |
| `out_slot_valid[WIDTH]` | saída | `in_slot_valid` | slots válidos; todos em 1 na v1 |
| `out_inst[WIDTH]` | saída | `in_inst` | instruções, slot 0 primeiro em ordem de programa |
| `out_pc[WIDTH]` | saída | `in_pc` | PC de cada slot |
| `dec_redirect_valid` | entrada | `redirect_valid` | o Decode achou um `JAL` (pulso de um ciclo) |
| `dec_redirect_pc` | entrada | `redirect_pc` | alvo do `JAL` |

### Pipeline-Control

| Porta | Dir. | Significado |
|---|---|---|
| `be_redirect_valid` | entrada | redirect do back end: desvio mal previsto ou exceção, já escolhido pelo controle entre as fontes |
| `be_redirect_pc` | entrada | PC correto |

## Comportamento

### Próximo PC

Na borda do relógio, nesta prioridade (a primeira condição verdadeira vence):

| Prioridade | Condição | Próximo PC |
|---|---|---|
| 1 | `reset` | `RESET_PC` |
| 2 | `be_redirect_valid` | `be_redirect_pc` |
| 3 | `dec_redirect_valid` | `dec_redirect_pc` |
| 4 | `out_ready = 0` | não muda (stall) |
| 5 | caso normal | `pc + 4 × WIDTH` |

```
out_valid = !reset && !be_redirect_valid && !dec_redirect_valid
```

### O que o consumidor pode assumir

- **Sem caminho errado no ciclo do redirect.** Num ciclo com qualquer redirect,
  o bundle na saída foi buscado pelo PC antigo, e `out_valid` fica em 0. O
  Decode não precisa descartar nada vindo do Fetch.
- **Stall estável.** Com `out_ready = 0` e sem redirect, `out_inst` e `out_pc`
  não mudam de um ciclo para o outro.
- **Redirect vence stall.** Um redirect é obedecido mesmo com `out_ready = 0`:
  o bundle parado está no caminho errado.
- **Custo de um `JAL`: 1 ciclo de bolha.** O Decode avisa no ciclo seguinte ao
  que aceitou o bundle com o salto. Os slots à direita do `JAL` no mesmo bundle
  são mortos pelo Decode (`out_slot_kill`); o bundle seguinte, pelo Fetch.

### O que o Fetch espera dos vizinhos

- **Alvos alinhados em 4 bytes.** O Fetch não confere o alinhamento do
  `be_redirect_pc` nem do `dec_redirect_pc` (ponto em aberto 4 da
  especificação).
- **Flush junto com o redirect.** Quem levanta `be_redirect_valid` deve levantar
  o `flush` do Decode no mesmo ciclo; senão um bundle do caminho errado parado no
  Decode segue adiante (ponto em aberto 3).

## Pendências

Previsto na especificação, em "Versões" e "Pontos em aberto":

- Predição de desvios (v3) e RAS (v4). Os campos `pred_taken` e `pred_target`
  que o `fu_req_t` espera ainda não têm caminho até a Branch Unit (ponto 1).
- Fetch Buffer e memória síncrona com 1 ciclo de latência (v2, ponto 2).
- Bundles parciais (`out_slot_valid` com zeros à direita), necessários quando
  houver desvio previsto como tomado no meio do bundle (v3).

## Teste

```sh
make test T=fetch          # tb/unit/fetch_tb.sv, casos T1 a T10, WIDTH 1 a 4
make test T=fetch_decode   # tb/integration/fetch_decode_tb.sv, caso T11
make lint
```

| Casos | O que cobrem |
|---|---|
| T1, T2 | reset |
| T3, T4 | busca sequencial e stall |
| T5 a T7 | redirects e prioridade |
| T8 a T10 | alvo fora do múltiplo de `4 × WIDTH`, PC acima de 4 GB, reset no meio |
| T11 | Fetch + Decode real com `JAL` e back-pressure aleatória: nenhuma instrução do caminho errado passa |

A descrição de cada caso está na especificação, em "Casos de teste
obrigatórios".
