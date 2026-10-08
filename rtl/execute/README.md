# rtl/execute

Unidades funcionais do estágio [Execute](https://github.com/SoaresDavidson/superscalar-riscv/wiki/Execute). Este README é o contrato de interface dos módulos implementados; o comportamento do estágio está no wiki.

| Arquivo | Conteúdo | Estado |
|---|---|---|
| `execute_pkg.sv` | Tipos compartilhados: larguras, operações, requisição/resposta das FUs | pronto |
| `alu.sv` | ALU inteira | pronto |
| Branch Unit, AGU, `execute.sv` | — | a fazer |

## `execute_pkg`

| Item | Valor / descrição |
|---|---|
| `XLEN` | 64 — largura dos dados |
| `REG_W` | 7 — especificador de registrador (128 registradores) |
| `AGE_W` | 8 — identificação de ordem da instrução (**proposta**) |
| `exec_op_t` | Todas as operações do Execute; o Decode traduz o opcode para este enum |
| `fu_of(op)` | Qual FU executa a operação (`FU_ALU`, `FU_BRANCH`, `FU_AGU`, `FU_NONE`) |
| `age_is_younger(a, b)` | `a` é mais nova que `b`, com wraparound; válido enquanto houver menos de `2^(AGE_W-1)` instruções em voo |
| `fu_req_t` | Requisição Issue → FU |
| `fu_resp_t` | Resposta FU → write-back |
| `redirect_t` | Branch Unit → Pipeline-Control |

## `alu`

### Portas

| Porta | Direção | Descrição |
|---|---|---|
| `clk` | in | relógio |
| `reset` | in | síncrono, ativo em alto |
| `flush` | in | um desvio de idade `flush_age` foi mal predito |
| `flush_age` | in | idade do desvio que causou o flush |
| `req_valid` / `req_ready` | in / out | handshake da requisição |
| `req` | in | `fu_req_t` |
| `resp_valid` / `resp_ready` | out / in | handshake da resposta |
| `resp` | out | `fu_resp_t` |

Uma transferência acontece na borda de subida em que `valid` e `ready` estão ambos em 1.

### Comportamento

- **Latência 1 ciclo, vazão 1 por ciclo**: operação combinacional seguida de um registrador de saída.
- **Back-pressure**: com `resp_ready = 0`, o resultado fica parado na saída e `req_ready` cai. Nada é perdido nem duplicado.
- **Flush seletivo**: com `flush = 1`, morrem as instruções **mais novas** que `flush_age` — a guardada na saída (o `resp_valid` é mascarado já no mesmo ciclo) e a que está chegando. Uma instrução **mais antiga** guardada na saída sobrevive.
- **`x0`**: a ALU não trata `x0`; repassa `wr_en` como recebeu. Cabe ao Decode entregar `wr_en = 0` quando `rd = x0`.
- **Exceções**: nunca gera (`exception = 0`, `cause = CAUSE_NONE`).
- Campos ignorados: `pred_taken`, `pred_target`. `src2` é ignorado quando `use_imm = 1`.

### Operações

O segundo operando (`B`) é `imm` quando `use_imm = 1` e `src2` caso contrário.

| `op` | Resultado |
|---|---|
| `ALU_ADD` / `ALU_SUB` | `src1 + B` / `src1 - B` (sem detecção de overflow) |
| `ALU_AND` / `ALU_OR` / `ALU_XOR` | operação bit a bit |
| `ALU_SLT` / `ALU_SLTU` | 1 se `src1 < B`, com sinal / sem sinal |
| `ALU_SLL` / `ALU_SRL` / `ALU_SRA` | deslocamento de `src1` pelos **6 bits baixos** de `B` |
| `ALU_LUI` | `imm` |
| `ALU_AUIPC` | `pc + imm` |

### Teste

`make test T=alu` — `tb/unit/alu_tb.sv`: casos dirigidos (limites aritméticos, deslocamentos acima de 32 bits, `slt` vs. `sltu`, imediato, mesmo registrador como fonte e destino, `x0`), back-pressure, flush com instrução mais antiga e mais nova em voo, flush no wraparound de `age` e 500 operações aleatórias contra um modelo de referência, com back-pressure aleatório.
