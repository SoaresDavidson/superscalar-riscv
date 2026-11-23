# Dispatch

> Rascunho de especificação, a ser revisado pela equipe e movido para a wiki.
> Baseado no `execute_pkg` e no Decode do branch `matheus#decode` (07/11).

Recebe do Decode um bundle de até `W` instruções e, para cada uma, reserva
uma entrada no ROB, uma tag no Rename (se escreve registrador) e uma entrada
na estação de reserva (RS). Há duas RS: a INT (ALU e desvio) e a MEM
(loads e stores). Se faltar algum recurso, o bundle inteiro espera
(decisão 15).

## Vizinhos

| Vizinho | Entrega ao dispatch | Recebe do dispatch |
|---|---|---|
| Decode | `uop_t[W]`, máscaras `out_dep_rs1`, `out_dep_rs2`, `out_dep_rd` | `out_ready` |
| Rename (`PRFRename`) | `dispatch_ready`, `dst_tag`, `old_tag`, tags e prontos das fontes | `rs1`, `rs2`, `rd`, `writes_rd`, as três máscaras, `rob_ready`, `rs_ready` |
| ROB (`retire_team`) | entradas livres, `age` de cada slot (`rob_age`) | uma entrada por instrução, e o `uop_t` do bundle (`rob_uop`) |
| RS INT e RS MEM | entradas livres | instrução a emitir |

As máscaras de dependência do Decode já estão no formato do `PRFRename`
(one-hot por slot) e são repassadas sem conversão.

## Regras

- Todo slot válido pede uma entrada no ROB.
- Todo slot com `has_dest = 1` pede uma tag.
- A RS depende de `fu_of(op)`:

| `fu_of(op)` | Inclui | RS |
|---|---|---|
| `FU_ALU` | ALU, instruções `W`, `lui`, `auipc`, link do `jal` (`ALU_PC4`) | INT, para a ALU |
| `FU_BRANCH` | desvios condicionais, `jalr` | INT, para a unidade de desvio |
| `FU_AGU` | loads e stores | MEM |
| `FU_NONE` | ilegais (`illegal = 1`) e instruções de sistema (`serializing = 1`) | nenhuma: entra no ROB, e o Retirement trata |

- Fonte com produtor no mesmo bundle recebe o `dst_tag` do escritor anterior
  mais próximo, com pronto = 0 (feito pelo Rename a partir das máscaras).

## Condição de aceite

Por slot `k`, o dispatch monta quatro máscaras de `W` bits: `valid[k]` (pede
ROB), `has_dest[k]` (pede tag), `to_int[k]` e `to_mem[k]` (pedem RS). As
contagens `n_rob`, `n_int` e `n_mem` são o número de bits em 1 de cada
máscara.

```
rob_ok       = rob_free >= n_rob
rs_ok        = int_free >= n_int && mem_free >= n_mem
decode_ready = rob_ok && rs_ok && rename.dispatch_ready
accept       = decode.out_valid && decode_ready && !flush
```

- `decode_ready` vai para o `out_ready` do Decode; o bundle entra quando
  `accept = 1`.
- A condição das tags é calculada pelo Rename (`dispatch_ready`).
- `rob_ok` vai para o `rob_ready` do Rename e `rs_ok` para o `rs_ready`: ele
  só aloca tags quando os dois estão em 1, ou seja, quando o bundle entra.

## Entrada na RS

Uma fonte que a instrução não usa (`rs*_valid = 0`) entra com `ready = 1` e
valor 0. A instrução está pronta para emissão quando
`busy && src1_ready && src2_ready`.

**RS INT** (alimenta a ALU e a unidade de desvio; a unidade de cada entrada é
`fu_of(op)`, então não há escolha de porta)

| Grupo | Campos |
|---|---|
| Controle | `busy` |
| Fonte 1 e fonte 2 | `src*_ready`, `src*_tag` |
| Execução | `op`, `imm`, `use_imm`, `pc`, `dst_tag`, `wr_en`, `age`, `pred_taken`, `pred_target` |

Na emissão, os campos de execução e os valores lidos do banco pelas tags formam o
`fu_req_t`.

**RS MEM** (alimenta a AGU)

| Grupo | Campos |
|---|---|
| Controle | `busy` |
| Fonte 1 (base do endereço) | `src1_ready`, `src1_tag` |
| Fonte 2 (dado do store; load entra pronto) | `src2_ready`, `src2_tag` |
| Execução | `op` (`AGU_*`: tamanho, sinal e direção), `imm`, `dst_tag`, `wr_en`, `age` |

Em relação à RS INT, saem `use_imm` (o endereço
é sempre `rs1 + imm`), `pc` (guardado no ROB), `pred_taken` e `pred_target`.

As RS guardam só tags (decisão 16 da wiki): os valores são lidos do banco
físico na emissão (`docs/rs/RS.md`).

## Casos difíceis

1. **`x0`.** Fonte com `rs*_valid = 0` vai ao Rename como registrador 0, que
   devolve pronto com valor 0; o campo `rs*` não é lido. Destino `x0` chega com
   `has_dest = 0` e não pede tag.
2. **Dependências no bundle.** O escritor anterior mais próximo nunca é um
   slot que escreve em `x0` nem um slot inválido (garantido pelo Decode). Um
   slot que lê e escreve o mesmo registrador lê o valor antigo.
3. **Wakeup no mesmo ciclo.** Ao escrever uma entrada, a RS compara as tags
   das fontes com os barramentos de wakeup daquele ciclo; se houver
   coincidência, a fonte entra pronta. Sem isso, a instrução perde o anúncio e
   espera para sempre.
4. **Flush no mesmo ciclo.** Com `flush = 1`, `accept = 0`: nada é alocado no
   ROB, nas RS ou no Rename (o `PRFRename` já dá prioridade ao flush).

## Síntese (sky130, 25 ns)

Medida em 20/11 com o LibreLane 3.0.17, no fluxo completo (síntese,
posicionamento e roteamento, até o GDS), com `USE_SLANG`,
`SYNTH_ABC_BUFFERING`, relógio de 25 ns e o SDC genérico (5 ns de atraso
externo na entrada e na saída). Bloco de 600 x 600 µm (`DIE_AREA`), por
causa dos ~1.900 pinos.

| Células | Área das células | Setup (pior canto) | Hold | DRC, LVS, antena |
|---|---|---|---|---|
| 1.413 | 7.083 µm² | +7,27 ns (`max_ss_100C_1v60`) | +10,08 ns | passam |

O dispatch é combinacional: só há caminhos de entrada para saída (não há
árvore de relógio nem caminhos entre registradores). Dos 15 ns que sobram
entre os atrasos externos, ele usa cerca de 7,5 ns no pior canto, contando
os fios até os pinos. Antes do posicionamento, o caminho mais lento
atravessava 8 portas:

```
op do slot 1 → fu_of(op) → to_mem → n_mem → mem_free >= n_mem → rs_ok → accept → mem_wr[1]
```

É o custo do tudo ou nada: o `accept` depende da contagem de todos os slots
e alimenta todas as máscaras. No `core`, o caminho que vai pesar é a soma
Rename + Dispatch, porque o `ren_dispatch_ready` também entra no
`dec_ready`. Sobram avisos de slew nos cantos lentos (até 131), dos fios
até os pinos na borda; dentro do `core`, esses sinais viram fios internos.

## Pontos em aberto

**Interface com os vizinhos**

1. ~~**Espaço nas RS no aceite do Rename.**~~ **Resolvido (13/11):** o
   `PRFRename` ganhou a entrada `rs_ready` (branch `davi#rename`), e o
   dispatch liga ali o `rs_ok`.
2. ~~**Interface do ROB.**~~ **Resolvido (20/11):** o ROB é o `retire_team`
   (PR #18). O dispatch liga `rob_free`, `rob_alloc`, `rob_entry` e
   `rob_uop`; o ROB aloca uma linha de `W` vias por bundle (`rob_free` vale
   `W` ou 0), e o slot `k` vai para a via `k`.
3. ~~**Identificação da instrução (`age`).**~~ **Resolvido (20/11):** o
   `age` vem do ROB, pela saída `rob_age[W]`, e o dispatch o copia nas
   entradas das RS. Fica a confirmar pelo grupo, junto com os outros pedidos
   do PR #18.

**Conteúdo da entrada na RS**

4. ~~**A RS guarda valores ou só tags?**~~ **Resolvido: só tags** (decisão
   16 da wiki). Os valores são lidos na emissão, pelas portas `read_tag ->
   read_data` do `PRFRename`.
5. **Informação de predição.** A Branch Unit precisa de `pred_taken` e
   `pred_target`, mas o `uop_t` não tem esses campos.

**Flush**

6. **Modelo de flush.** O Execute faz flush seletivo na execução; o
   `PRFRename` só se recupera no commit. Define o que o dispatch e as RS
   descartam, e quando.

**ROB**

8. **Tipo da instrução de sistema (`rob_sys_kind`).** O `retire_team` pede,
   por slot, 3 bits dizendo se é `ecall`, `ebreak`, `mret`, `fence`,
   `fence.i` ou CSR. O `uop_t` não tem essa informação; o pedido do Carlos é
   um campo `sys_kind` no `uop_t`, o que muda o contrato Decode–Execute
   (Matheus). Até lá, a entrada fica em 0 no `core`.
9. **`rob_uop` inteiro ou só o necessário.** O `retire_team` só usa do
   `uop_t` o `op`, para separar load de store (`is_load`). Repassar o
   `uop_t` inteiro são 3 x 158 fios; a alternativa é um bit `is_load` (e o
   `sys_kind`) no `rob_entry_t`, o que muda o adaptador do Carlos. Hoje: o
   `uop_t` inteiro, que não exige mudança do lado do ROB.

**Memória**

7. **Emissão do store.** O store sai da RS MEM só com os dois operandos
   prontos, ou calcula o endereço assim que a base (`src1`) fica pronta?
   Proposta inicial: esperar os dois. Depende da parte de memória (Shen &
   Lipasti, 5.3).

**Resolvidos na reunião de alinhamento** (AGENTS.md, 06/11): sem
multiplicador (a extensão M é ilegal); instruções de sistema vão para o
Retirement, não para uma RS; o Decode entrega as dependências no formato do
Rename, com `out_dep_rd`; um pacote só (`execute_pkg`), com `tag_t` de
`TAG_W` bits.