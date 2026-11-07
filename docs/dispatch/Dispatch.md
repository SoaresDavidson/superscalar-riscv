# Dispatch

> Rascunho de especificação, a ser revisado pela equipe e movido para a wiki.

Recebe do Decode um bundle de até `W` instruções e, para cada uma, reserva
uma entrada no ROB, uma tag no Rename (se escreve registrador) e uma entrada
na estação de reserva (RS). Há duas RS: a INT (ALU e desvio) e a MEM
(loads e stores). Se faltar algum recurso, o bundle inteiro espera
(decisão 15).

## Vizinhos

| Vizinho | Entrega ao dispatch | Recebe do dispatch |
|---|---|---|
| Decode | `uop_t[W]`, dependências do bundle | `ready` |
| Rename | `dst_tag`, `old_tag`, tags e prontos das fontes | `rs1`, `rs2`, `rd`, `writes_rd` |
| ROB | entradas livres, índices | uma entrada por instrução |
| RS INT e RS MEM | entradas livres | instrução a emitir |

## Regras

- Todo slot válido pede uma entrada no ROB.
- Todo slot com `has_dest = 1` pede uma tag.
- A RS depende de `uop_class`:

| `uop_class` | RS |
|---|---|
| `UC_ALU` | INT (porta 0 ou 1) |
| `UC_BRANCH`, `UC_JUMP` | INT (só porta 0) |
| `UC_LOAD`, `UC_STORE` | MEM |
| `UC_ILLEGAL` | nenhuma: entra no ROB já terminada, com exceção |
| `UC_MUL` | nenhuma por enquanto (ver item 1) |
| `UC_SYSTEM` | em aberto (ver item 2) |

- Fonte com produtor no mesmo bundle recebe o `dst_tag` do escritor anterior
  mais próximo, com pronto = 0.

## Condição de aceite

Por slot `k`, o dispatch monta quatro máscaras de `W` bits: `valid[k]` (pede
ROB), `has_dest[k]` (pede tag), `to_int[k]` e `to_mem[k]` (pedem RS). As
contagens `n_rob`, `n_int` e `n_mem` são o número de bits em 1 de cada
máscara.

```
space_ok     = rob_free >= n_rob && int_free >= n_int && mem_free >= n_mem
decode_ready = space_ok && rename.dispatch_ready
accept       = decode.out_valid && decode_ready
```

- `decode_ready` vai para o `out_ready` do Decode; o bundle entra quando
  `accept = 1`.
- A condição das tags é calculada pelo Rename (`dispatch_ready`).
- `space_ok` é ligado ao `rob_ready` do Rename, para que ele só aloque tags
  quando o bundle entra (ver item 4).

## Entrada na RS

Uma fonte que a instrução não usa entra com `ready = 1`. A instrução está
pronta para emissão quando `busy && src1_ready && src2_ready`.

**RS INT** (portas 0 e 1)

| Grupo | Campos |
|---|---|
| Controle | `busy`, `port0_only` (1 para `UC_BRANCH` e `UC_JUMP`) |
| Fonte 1 e fonte 2 | `src*_ready`, `src*_tag`, `src*_data` |
| Execução | `op`, `imm`, `use_imm`, `pc`, `dst_tag`, `wr_en`, `age`, `pred_taken`, `pred_target` |

Na emissão, os campos de execução e `src1_data`/`src2_data` formam o
`fu_req_t`; `dst_tag` vai para o campo `rd`.

**RS MEM** (porta 2)

| Grupo | Campos |
|---|---|
| Controle | `busy` |
| Fonte 1 (base do endereço) | `src1_ready`, `src1_tag`, `src1_data` |
| Fonte 2 (dado do store; load entra pronto) | `src2_ready`, `src2_tag`, `src2_data` |
| Execução | `imm`, `is_store`, `mem_size`, `mem_unsigned`, `dst_tag`, `wr_en`, `age` |

Em relação à RS INT, saem `port0_only` (uma só porta), `use_imm` (o endereço
é sempre `rs1 + imm`), `pc` (guardado no ROB), `op`, `pred_taken` e
`pred_target`.

`src1_data` e `src2_data` dependem do item 7.

## Casos difíceis

*A escrever.*

## Pontos em aberto

Questões que a equipe precisa decidir antes de fechar esta especificação.
Cada item diz por que afeta o dispatch.

**Roteamento**

1. **`UC_MUL` sem multiplicador.** O branch `execute` removeu o MUL, mas o
   `core_pkg` ainda tem `UC_MUL`. O dispatch manda essas instruções para
   alguma RS ou as trata como ilegais?
2. **Instruções `UC_SYSTEM`** (decisões 9 e 10). Entram na RS INT esperando
   ser as mais antigas, ou ficam fora das RS e o ROB as executa no topo?

**Interface com os vizinhos**

3. **Formato das dependências do bundle.** O Decode entrega o índice do
   produtor e um bit `in_bundle`; o `PRFRename` espera one-hot e um `rd_dep`
   que o Decode não gera. O dispatch fica entre os dois e teria de converter.
4. **Espaço nas RS no aceite do Rename.** O `PRFRename` só recebe
   `rob_ready`. Se uma RS estiver cheia e ele alocar tags mesmo assim, as
   tags vazam.
5. **Interface do ROB.** O módulo ainda não existe. O dispatch precisa saber
   quantas entradas estão livres e quais índices o bundle recebe.
6. **Identificação da instrução (`age`).** O Execute usa `age_t` no flush
   seletivo. Se for o índice do ROB, quem atribui é o dispatch.

**Conteúdo da entrada na RS**

7. **A RS guarda valores ou só tags?** O Rename hoje devolve `src1_data` e
   `src2_data`. Define quais campos o dispatch escreve na RS.
8. **Informação de predição.** A Branch Unit precisa de `pred_taken` e
   `pred_target`, mas o `uop_t` não tem esses campos. O dispatch precisa
   recebê-los de algum lugar para repassar.
9. **Tipos compartilhados.** A tag tem 7 bits no `execute_pkg` e 6 no
   `PRFRename`, e os dois pacotes repetem nomes como `ALU_ADD`. O dispatch
   usa os dois para montar a entrada.

**Flush**

10. **Modelo de flush.** O Execute faz flush seletivo na execução; o
    `PRFRename` só se recupera no commit. Define o que o dispatch e as RS
    descartam, e quando.

**Memória**

11. **Emissão do store.** O store sai da RS MEM só com os dois operandos
    prontos, ou calcula o endereço assim que a base (`src1`) fica pronta? O
    dado (`src2`) só é necessário no commit. Proposta inicial: esperar os
    dois. Depende da parte de memória (Shen & Lipasti, 5.3).