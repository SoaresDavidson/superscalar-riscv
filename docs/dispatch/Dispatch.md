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
| Rename (`PRFRename`) | `dispatch_ready`, `dst_tag`, `old_tag`, tags, prontos e valores das fontes | `rs1`, `rs2`, `rd`, `writes_rd`, as três máscaras, `rob_ready`, `rs_ready` |
| ROB | entradas livres, índices | uma entrada por instrução |
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
| Fonte 1 e fonte 2 | `src*_ready`, `src*_tag`, `src*_data` |
| Execução | `op`, `imm`, `use_imm`, `pc`, `dst_tag`, `wr_en`, `age`, `pred_taken`, `pred_target` |

Na emissão, os campos de execução e `src1_data`/`src2_data` formam o
`fu_req_t`.

**RS MEM** (alimenta a AGU)

| Grupo | Campos |
|---|---|
| Controle | `busy` |
| Fonte 1 (base do endereço) | `src1_ready`, `src1_tag`, `src1_data` |
| Fonte 2 (dado do store; load entra pronto) | `src2_ready`, `src2_tag`, `src2_data` |
| Execução | `op` (`AGU_*`: tamanho, sinal e direção), `imm`, `dst_tag`, `wr_en`, `age` |

Em relação à RS INT, saem `use_imm` (o endereço
é sempre `rs1 + imm`), `pc` (guardado no ROB), `pred_taken` e `pred_target`.

`src1_data` e `src2_data` dependem do item 4.

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

## Pontos em aberto

**Interface com os vizinhos**

1. ~~**Espaço nas RS no aceite do Rename.**~~ **Resolvido (13/11):** o
   `PRFRename` ganhou a entrada `rs_ready` (commit `b8cd458`, branch
   `davi#rename`), e o dispatch liga ali o `rs_ok`.
2. **Interface do ROB.** O módulo ainda não existe. O dispatch precisa saber
   quantas entradas estão livres e quais índices o bundle recebe.
3. **Identificação da instrução (`age`).** O `execute_pkg` usa `age_t` de 8
   bits (questão em aberto 2 dele). Se for o índice do ROB, quem atribui é o
   dispatch, e o ROB pode ter no máximo 128 entradas.

**Conteúdo da entrada na RS**

4. **A RS guarda valores ou só tags?** O Rename hoje devolve `src1_data` e
   `src2_data`. Define quais campos o dispatch escreve na RS.
5. **Informação de predição.** A Branch Unit precisa de `pred_taken` e
   `pred_target`, mas o `uop_t` não tem esses campos.

**Flush**

6. **Modelo de flush.** O Execute faz flush seletivo na execução; o
   `PRFRename` só se recupera no commit. Define o que o dispatch e as RS
   descartam, e quando.

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