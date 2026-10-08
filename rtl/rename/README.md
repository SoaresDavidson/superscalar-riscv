# Register rename RTL

As três variantes da [wiki](../../superscalar-riscv.wiki/Register-Rename.md) têm
uma porta de dispatch, uma de writeback e uma de commit:

| Módulo | Tag | Resultado antes do commit | Estado após commit |
|---|---|---|---|
| `RRF` | índice do RRF | entrada do RRF | copiado para o ARF |
| `ROBRename` | índice do ROB | entrada do ROB | copiado para o ARF |
| `PRFRename` | índice do PRF | registrador físico | registrador físico passa a arquitetural |

## Interface com o ROB externo (decisão 14)

Vale para `PRFRename` e `RRF`. O rename não guarda ordem de programa: o ROB é
um módulo à parte, e o rename é uma tabela passiva de tags que reage a
comandos (alocar, promover, liberar, restaurar no flush). Em `ROBRename` o ROB
é o próprio banco de renomeação e esta separação não existe.

### Dispatch

| Sinal | Sentido | Significado |
|---|---|---|
| `dispatch_valid` | entrada | há uma instrução tentando entrar |
| `rs1`, `rs2`, `rd`, `writes_rd` | entrada | registradores arquiteturais e se a instrução escreve `rd` |
| `rob_ready` | entrada | o ROB tem entrada livre |
| `dispatch_ready` | saída | há tag livre, ou a instrução não precisa de tag |
| `src_ready`, `src1_data`, `src2_data`, `src1_tag`, `src2_tag` | saída | resolução das fontes |
| `dst_tag` | saída | tag nova alocada para `rd` |
| `old_tag` | saída | `map[rd]` de antes da alocação |

A instrução entra quando `dispatch_valid && dispatch_ready && rob_ready`. Só
aloca tag se `writes_rd && rd != 0`; escritas em `x0` não alocam nada. O
`rob_ready` entra no rename para que nunca seja alocada uma tag que o ROB
recusou.

`rs1` e `rs2` são resolvidos **antes** da alocação de `rd`, permitindo ler o
valor anterior quando uma instrução usa o mesmo registrador como fonte e
destino. Cada fonte sai com `src_ready=1` e `src*_data`, ou com `src_ready=0` e
`src*_tag`.

`old_tag` só existe no ciclo do dispatch: na mesma borda, `map[rd]` recebe
`dst_tag`. O ROB guarda `dst_tag`, `old_tag` e `has_dest = writes_rd && rd != 0`
na entrada da instrução.

### Writeback

`wb_valid`, `wb_tag` e `wb_data` tornam o resultado disponível. O produtor
também deve transmitir `(tag, data)` às reservation stations que já receberam
a tag, pois este módulo não contém a lógica de wakeup. O ROB observa o mesmo
writeback para marcar a própria entrada como terminada.

Um writeback no mesmo ciclo do dispatch é repassado às fontes (bypass): se
`wb_tag` for a tag de uma fonte, ela sai com `src_ready=1` e
`src*_data=wb_data`. Sem o bypass, a instrução perderia o broadcast desse ciclo
e esperaria a tag para sempre. A tag 0 (`x0`) não participa do bypass.

### Commit

| Sinal | Sentido | Significado |
|---|---|---|
| `commit_valid` | entrada | o ROB retira uma instrução **com destino** neste ciclo |
| `commit_rd` | entrada | registrador arquitetural atualizado |
| `commit_tag` | entrada | tag que passa a arquitetural |
| `commit_old_tag` | entrada | tag substituída, que volta a ficar livre |

O commit é sempre em ordem de programa, mesmo que o writeback chegue fora de
ordem: quem decide se o head pode retirar é o ROB. Entradas sem destino
(stores, desvios, escritas em `x0`) são retiradas sem nenhum comando ao rename.
O rename não tem `commit_ready`: aceita sempre o comando de commit.

### Flush

`flush` descarta todos os escritores especulativos e restaura o mapeamento
confirmado; o ROB esvazia a própria fila. Um commit no mesmo ciclo do flush
não é especulativo e é aplicado junto com a restauração. Como `committed_map`
só muda na borda, cada estrutura aplica esse commit por cima do estado
restaurado:

| Submódulo | Flush | Commit no mesmo ciclo |
|---|---|---|
| `PRFFreeList` | `head <= tail`, `count <= ENTRIES-32` | `commit_old_tag` entra em `tail`; `head <= next(tail)` |
| `PRFMapTable` | `map <= committed_map` | `map[commit_rd] <= commit_tag` |
| `PRFCommittedTable` | não muda | `committed_map[commit_rd] <= commit_tag` |
| `PRFRegFile` | estados não `AR` voltam a `FREE` | `commit_tag` vira `AR`, `commit_old_tag` vira `FREE` |

O controle do pipeline deve cancelar os
writebacks das instruções descartadas, pois uma tag pode ser reutilizada.

### Em aberto

- Como o valor retirado chega à verificação final (decisão 13): uma porta de
  leitura `commit_tag -> commit_data` no rename ou outro caminho. Não decidido.
- A largura atual é de **uma instrução por ciclo**; o projeto prevê largura 3,
  que exige renomeação entre os slots do mesmo bundle e portas adicionais.

## Implementação

Cada variante é um módulo independente, sem código compartilhado. `ROBRename`
não tem `ROB_ENTRIES`: o ROB é o próprio banco de renomeação (`ENTRIES`).

`PRFRename.sv` contém o topo e quatro submódulos:

| Submódulo | Função |
|---|---|
| `PRFFreeList` | fila circular das tags livres; no flush, `head` volta a `tail` |
| `PRFMapTable` | `x0..x31 -> tag` especulativo; fornece `src*_tag` e `old_tag` |
| `PRFCommittedTable` | `x0..x31 -> tag` arquitetural; restaura a map table no flush |
| `PRFRegFile` | `value[]` e `state[]` por tag (`FREE`, `RB_NOT_VALID`, `RB_VALID`, `AR`) |

Para verificar (hoje só `PRFRename` está em `rtl/rename/`):

```sh
make test T=PRFRename
```
