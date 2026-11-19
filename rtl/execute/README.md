# rtl/execute

Unidades funcionais do estágio [Execute](https://github.com/SoaresDavidson/superscalar-riscv/wiki/Execute). Este README é o contrato de interface dos módulos implementados; o comportamento do estágio está no wiki.

> **Mudanças de contrato vindas do Decode (branch `matheus#decode`), pendentes de aval do dono do Execute.** Resumo do que mudou no `execute_pkg.sv` e por quê:
>
> 1. **`uop_t` mora aqui agora.** Pacote único (`AGENTS.md`): o `rtl/core_pkg.sv` foi apagado. Os dois pacotes declaravam `ALU_ADD`, `ALU_SUB`, `ALU_SLL`… e o Dispatch, que precisa dos dois ao mesmo tempo, colidia.
> 2. **`rd` → `dst_tag` em `fu_req_t` e `fu_resp_t`, com `TAG_W` bits.** `REG_W = 5` está certo para o registrador *arquitetural*, mas esses dois campos carregam a **tag física** — o `dst_tag` que o rename devolve e o `wb_tag` que o CDB transmite. Com 5 bits a tag (6 bits hoje) era truncada e o write-back escrevia no registrador físico errado. A questão em aberto 1 da página Execute pedia "7 → 5"; o certo é separar os dois conceitos, não estreitar um no outro.
> 3. **`ALU_PC4` novo no `exec_op_t`.** `JAL` não passa pelo Execute (decisão 7), mas ainda precisa gravar `pc + 4` em `rd`, e a ALU é onde isso cabe.
>
> **Ações necessárias no RTL do Execute:**
>
> | Arquivo | O quê | Natureza |
> |---|---|---|
> | `alu.sv`, `agu.sv` | `resp_q.rd <= req.rd` → `resp_q.dst_tag <= req.dst_tag` | renomeação; nenhum resultado esperado de testbench muda |
> | `alu.sv` | acrescentar `ALU_PC4: result = pc + 4;` ao `case` de 64 bits | comportamento novo, precisa de caso no `alu_tb` |
> | `execute_pkg_tb.sv` | `fu_of(ALU_PC4) == FU_ALU`, e os `W`/`AGU_LD` novos | cobertura |
>
> O `ALU_PC4` é o único item que não é renomeação: sem ele, um `JAL` sai do
> Execute com `result = 0` e grava lixo em `rd`.

| Arquivo | Conteúdo | Estado |
|---|---|---|
| `execute_pkg.sv` | Tipos compartilhados: larguras, `uop_t`, operações, requisição/resposta das FUs | pronto |
| `alu.sv` | ALU inteira | pronto (pendente o rename `rd` → `dst_tag`) |
| `agu.sv` | Address Generation Unit | pronto (pendente o rename `rd` → `dst_tag`) |
| Branch Unit, `execute.sv` | — | a fazer |

## `execute_pkg`

| Item | Valor / descrição |
|---|---|
| `XLEN` | 64 — largura dos dados |
| `REG_W` | 5 — especificador de registrador **arquitetural**, `x0`–`x31` |
| `PRF_ENTRIES` | 64 — tamanho do banco físico. **Pendente:** é só o default do `PRFRename`, o grupo ainda não fixou |
| `TAG_W` | `$clog2(PRF_ENTRIES)` — a **tag física**, que é o que as FUs transportam |
| `AGE_W` | 8 — identificação de ordem da instrução (**proposta**) |
| `uop_t` | Micro-operação Decode → Rename/Dispatch, em registradores arquiteturais (sem tag) |
| `exec_op_t` | Todas as operações do Execute; o Decode traduz o opcode direto para este enum |
| `fu_of(op)` | Qual FU executa a operação (`FU_ALU`, `FU_BRANCH`, `FU_AGU`, `FU_NONE`) |
| `is_load(op)` | Load (ocupa a AGU mas escreve registrador depois, com o valor do Memory) |
| `age_is_younger(a, b)` | `a` é mais nova que `b`, com wraparound; válido enquanto houver menos de `2^(AGE_W-1)` instruções em voo |
| `fu_req_t` | Requisição Issue → FU |
| `fu_resp_t` | Resposta FU → write-back |
| `redirect_t` | Branch Unit → Pipeline-Control |

**`REG_W` x `TAG_W` x `age`** são três coisas distintas com nomes parecidos, e
confundi-las foi a causa do bug do item 2 acima:

| Nome | O quê | Quem usa |
|---|---|---|
| `REG_W` = 5 | registrador arquitetural `x0`–`x31` | `uop_t.rs1/rs2/rd` |
| `TAG_W` = 6 | registrador físico (tag de rename) | `fu_req_t.dst_tag`, `fu_resp_t.dst_tag`, `wb_tag` |
| `AGE_W` = 8 | posição na ordem de programa | flush seletivo |

**Consequência de `AGE_W = 8` que ninguém tinha escrito:** se `age` for o
índice do ROB, o ROB pode ter no máximo `2^(AGE_W-1)` = **128** entradas. Com
mais que isso, `age_is_younger` compara errado no wraparound e o flush
seletivo mata a instrução errada.

### `uop_t` e a fronteira Decode / Rename

O `uop_t` fala só em registradores **arquiteturais**: a tag ainda não existe
quando o Decode roda. O Dispatch monta o `fu_req_t` copiando os campos do
`uop_t` e substituindo `rd`/`has_dest` pelo `dst_tag`/`wr_en` que o rename
devolveu. Um campo `op` do tipo `exec_op_t` substitui os seis campos de
classificação que o `core_pkg` tinha (`uop_class`, `alu_op`, `mul_op`,
`br_op`, `mem_size`, `mem_unsigned`, `word_op`): a FU sai de `fu_of(op)`, o
tamanho e o sinal do acesso estão no `AGU_*`, e a semântica de 32 bits está no
`ALU_*W`. Detalhe campo a campo em `rtl/decode/README.md` e na §5 do
`docsDecode/Decode.md`.

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
| `ALU_PC4` | `pc + 4` — valor de link do `JAL`, que não passa pela Branch Unit (decisão 7) |

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
