# Dispatch

> Rascunho de especificação, a ser revisado pela equipe e movido para a wiki.

Recebe do Decode um bundle de até `W` instruções e, para cada uma, reserva
uma entrada no ROB, uma tag no Rename (se escreve registrador) e uma entrada
na fila de emissão. Se faltar algum recurso, o bundle inteiro espera
(decisão 15).

## Vizinhos

| Vizinho | Entrega ao dispatch | Recebe do dispatch |
|---|---|---|
| Decode | `uop_t[W]`, dependências do bundle | `ready` |
| Rename | `dst_tag`, `old_tag`, tags e prontos das fontes | `rs1`, `rs2`, `rd`, `writes_rd` |
| ROB | entradas livres, índices | uma entrada por instrução |
| Filas INT e MEM | entradas livres | instrução a emitir |

## Regras

- Todo slot válido pede uma entrada no ROB.
- Todo slot com `has_dest = 1` pede uma tag.
- A fila depende de `uop_class`:

| `uop_class` | Fila |
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

*A escrever.*

## Entrada na fila

*A escrever.*

## Casos difíceis

*A escrever.*

## Pontos em aberto

Questões que a equipe precisa decidir antes de fechar esta especificação.
Cada item diz por que afeta o dispatch.

**Roteamento**

1. **`UC_MUL` sem multiplicador.** O branch `execute` removeu o MUL, mas o
   `core_pkg` ainda tem `UC_MUL`. O dispatch manda essas instruções para
   alguma fila ou as trata como ilegais?
2. **Instruções `UC_SYSTEM`** (decisões 9 e 10). Entram na fila INT esperando
   ser as mais antigas, ou ficam fora das filas e o ROB as executa no topo?

**Interface com os vizinhos**

3. **Formato das dependências do bundle.** O Decode entrega o índice do
   produtor e um bit `in_bundle`; o `PRFRename` espera one-hot e um `rd_dep`
   que o Decode não gera. O dispatch fica entre os dois e teria de converter.
4. **Espaço nas filas no aceite do Rename.** O `PRFRename` só recebe
   `rob_ready`. Se uma fila estiver cheia e ele alocar tags mesmo assim, as
   tags vazam.
5. **Interface do ROB.** O módulo ainda não existe. O dispatch precisa saber
   quantas entradas estão livres e quais índices o bundle recebe.
6. **Identificação da instrução (`age`).** O Execute usa `age_t` no flush
   seletivo. Se for o índice do ROB, quem atribui é o dispatch.

**Conteúdo da entrada na fila**

7. **A fila guarda valores ou só tags?** O Rename hoje devolve `src1_data` e
   `src2_data`. Define quais campos o dispatch escreve na fila.
8. **Informação de predição.** A Branch Unit precisa de `pred_taken` e
   `pred_target`, mas o `uop_t` não tem esses campos. O dispatch precisa
   recebê-los de algum lugar para repassar.
9. **Tipos compartilhados.** A tag tem 7 bits no `execute_pkg` e 6 no
   `PRFRename`, e os dois pacotes repetem nomes como `ALU_ADD`. O dispatch
   usa os dois para montar a entrada.

**Flush**

10. **Modelo de flush.** O Execute faz flush seletivo na execução; o
    `PRFRename` só se recupera no commit. Define o que o dispatch e as filas
    descartam, e quando.
