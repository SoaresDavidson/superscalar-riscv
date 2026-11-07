# rtl/execute

Unidades funcionais do estágio [Execute](https://github.com/SoaresDavidson/superscalar-riscv/wiki/Execute). Este README é o contrato de interface dos módulos implementados; o comportamento do estágio está no wiki.

| Arquivo | Conteúdo | Estado |
|---|---|---|
| `execute_pkg.sv` | Tipos compartilhados: larguras, operações, requisição/resposta das FUs | pronto |
| `alu.sv` | ALU inteira | pronto |
| `agu.sv` | Address Generation Unit | pronto |
| Branch Unit, `execute.sv` | — | a fazer |

## `execute_pkg`

| Item | Valor / descrição |
|---|---|
| `XLEN` | 64 — largura dos dados |
| `REG_W` | 5 — especificador de registrador (32 registradores, RV64I) |
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
| `ALU_ADDW`/`ALU_SUBW`/`ALU_SLLW`/`ALU_SRLW`/`ALU_SRAW` | variantes RV64 `W`: operam nos 32 bits baixos e estendem o sinal do resultado para 64; deslocamento de 5 bits |

### Teste

`make test T=alu` — `tb/unit/alu_tb.sv`: casos dirigidos (limites aritméticos, deslocamentos acima de 32 bits, `slt` vs. `sltu`, imediato, mesmo registrador como fonte e destino, `x0`), back-pressure, flush com instrução mais antiga e mais nova em voo, flush no wraparound de `age` e 500 operações aleatórias contra um modelo de referência, com back-pressure aleatório.

## `agu`

Calcula `endereço = src1 + imm` e sinaliza exceção de desalinhamento. O acesso à memória em si pertence ao [[Memory]]. Mesma estrutura de registrador de saída, handshake e flush seletivo da ALU.

### Comportamento

- `result` carrega o endereço efetivo.
- **Alinhamento** conforme o tamanho do acesso (vindo do `op`): byte sempre alinhado; half exige `addr[0]=0`; word exige `addr[1:0]=0`; double exige `addr[2:0]=0`.
- **Exceção**: `exception=1` com `cause = CAUSE_LOAD_MISALIGNED` (loads) ou `CAUSE_STORE_MISALIGNED` (stores) quando desalinhado.
- **`wr_en`**: repassado. Loads escrevem `rd` (valor vem depois, do Memory); stores chegam com `wr_en=0`.
- **Pendente**: o dado do store (`src2`) até o Memory ainda não tem caminho definido.

### Operações

`AGU_LB/LBU/LH/LHU/LW/LWU/LD` (loads) e `AGU_SB/SH/SW/SD` (stores).

### Teste

`make test T=agu`. Casos: aritmética do endereço (offset positivo e negativo), alinhamento por tamanho, causa load vs store, desalinhamento vindo de `base+imm`, back-pressure, flush com mais antigo (sobrevive) e mais novo (morre), e 200 operações aleatórias contra modelo com back-pressure.
