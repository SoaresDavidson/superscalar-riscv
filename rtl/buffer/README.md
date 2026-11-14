# Buffers entre estágios

`PipeFifo` é a FIFO circular das fronteiras do front-end:

```
Fetch -> [PipeFifo] -> Decode -> [PipeFifo] -> Rename/Dispatch
```

São duas instâncias do mesmo módulo, só muda o dado empacotado. O ROB, as
Reservation Stations e o store buffer são estruturas próprias (ROB externo,
decisão 14; as RS seguem em aberto) e não usam este módulo.

## Flush é provisório

O `flush` desta FIFO **descarta todo o conteúdo**. Isso corresponde à
recuperação global no retire do desvio mal predito. A estratégia de recuperação
de desvios ainda não foi decidida (global no retire ou seletiva por tag/branch
mask). Se for seletiva, cada entrada passa a guardar a máscara do desvio e o
`flush` passa a invalidar só as entradas marcadas, o que muda esta interface e o
README. Até a decisão, não construa lógica em cima do descarte total.

## Interface

```systemverilog
module PipeFifo #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 4
) (
  input  logic              clk,
  input  logic              reset,  // síncrono, ativo-alto
  input  logic              flush,  // descarta todo o conteúdo

  input  logic              in_valid,
  output logic              in_ready,
  input  logic [DATA_W-1:0] in_data,

  output logic              out_valid,
  input  logic              out_ready,
  output logic [DATA_W-1:0] out_data
);
```

## Comportamento

| Item | Regra |
|---|---|
| Handshake | `valid`/`ready`: a transferência ocorre quando os dois estão altos |
| `in_ready` | `1` se há vaga. Depende só da ocupação, nunca de `out_ready` |
| `out_valid` | `1` se há entrada. A mais antiga já está em `out_data` |
| `out_data` | estável enquanto `out_valid && !out_ready` |
| Cheia | uma saída no ciclo não abre vaga para entrada no mesmo ciclo |
| `flush` | esvazia a FIFO; tem precedência sobre o handshake dos dois lados (entrada no mesmo ciclo é descartada, saída no mesmo ciclo não ocorre) |
| `reset` | esvazia a FIFO |
| `DEPTH` | qualquer valor `>= 1`; não precisa ser potência de 2 |

O dado é opaco. Quem instancia empacota o bundle em `DATA_W` bits, por exemplo
`{in_slot_valid, in_pc, in_inst}` entre Fetch e Decode, ou `uop_t[WIDTH]` com as
máscaras de dependência entre Decode e Dispatch. O bundle atravessa a FIFO
inteiro, o que preserva a saída tudo ou nada do Decode (decisão 15).

## Testbench

`tb/unit/PipeFifo_tb.sv` compara a cada ciclo `in_ready`, `out_valid` e
`out_data` com um modelo de referência. Roda com `DEPTH` = 1, 2, 3, 4 e 8
(`PARAMS_PipeFifo` no Makefile). Cobre fila cheia, entrada recusada, saída com
a FIFO cheia, entrada e saída no mesmo ciclo, wrap dos ponteiros, flush com
dados em voo, flush no mesmo ciclo do handshake e reset no meio da operação,
mais fases aleatórias com back-pressure e flush.
