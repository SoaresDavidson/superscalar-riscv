# Register rename RTL

`RRF` e `ROBRename` têm uma porta de dispatch, uma de writeback e uma de
commit. `PRFRename` recebe um bundle de `W` instruções por ciclo e tem `WB_N`
portas de writeback (veja "Bundle de largura `W`" abaixo). Variantes da
[wiki](../../superscalar-riscv.wiki/Register-Rename.md):

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
| `rs_ready` | entrada | a Reservation Station tem entrada livre |
| `dispatch_ready` | saída | há tag livre, ou a instrução não precisa de tag |
| `src_ready`, `src1_data`, `src2_data`, `src1_tag`, `src2_tag` | saída | resolução das fontes |
| `dst_tag` | saída | tag nova alocada para `rd` |
| `old_tag` | saída | `map[rd]` de antes da alocação |

A instrução entra quando `dispatch_valid && dispatch_ready && rob_ready &&
rs_ready`. Só aloca tag se `writes_rd && rd != 0`; escritas em `x0` não alocam
nada. `rob_ready` e `rs_ready` entram no rename para que nunca seja alocada uma
tag que o ROB ou a Reservation Station recusou.

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
| `PRFFreeList` | `head <= tail`, `count <= ENTRIES-32` | cada `commit_old_tag` válido entra em `tail`, em ordem; `head` vai para o `tail` novo |
| `PRFMapTable` | `map <= committed_map` | `map[commit_rd] <= commit_tag`, em ordem de slot |
| `PRFCommittedTable` | não muda | `committed_map[commit_rd] <= commit_tag`, em ordem de slot |
| `PRFRegFile` | estados não `AR` voltam a `FREE` | `commit_tag` vira `AR`, `commit_old_tag` vira `FREE`, em ordem de slot |

O controle do pipeline deve cancelar os
writebacks das instruções descartadas, pois uma tag pode ser reutilizada.

### Em aberto

- Como o valor retirado chega à verificação final (decisão 13): uma porta de
  leitura `commit_tag -> commit_data` no rename ou outro caminho. Não decidido.
- O número de portas de writeback (`WB_N`) depende das unidades funcionais
  (página Execute da wiki). O padrão do módulo é `WB_N = 1`.
- `RRF` e `ROBRename` ainda são de uma instrução por ciclo.

### Bundle de largura `W` (`PRFRename`)

As tabelas acima descrevem um slot. Em `PRFRename`, cada sinal por instrução é
um packed array indexado pelo slot `k = 0..W-1` (slot 0 é o mais antigo); o
handshake (`dispatch_valid`, `rob_ready`, `rs_ready`, `dispatch_ready`) é único para o
bundle. A especificação completa está na wiki, em "Bundle de largura `W`".

| Sinal | Sentido | Significado |
|---|---|---|
| `slot_valid[k]` | entrada | o slot `k` tem instrução |
| `rs1_dep[k]`, `rs2_dep[k]`, `rd_dep[k]` | entrada | one-hot de `W` bits vindo do Decode: bit `i < k` indica o escritor mais próximo dentro do bundle |
| `wb_*[p]` | entrada | `p = 0..WB_N-1`; o bypass compara cada fonte com todas as portas |
| `commit_*[k]` | entrada | até `W` commits por ciclo, em ordem de programa |

- **Tudo ou nada**: o slot `k` aloca se `slot_valid[k] && writes_rd[k] && rd[k] != 0`;
  `dispatch_ready` exige tantas tags livres quanto slots que alocam.
- **Alocação**: o slot `k` recebe a tag da Free List seguinte às dos slots
  anteriores que alocam.
- **Encadeamento**: se `rs1_dep[k]` tem o bit `i`, `src1_tag[k] = dst_tag[i]`
  e `src_ready[k][0] = 0`, sem bypass. Idem para `rs2`. Se `rd_dep[k]` tem o
  bit `i`, `old_tag[k] = dst_tag[i]`.
- **Mesmo `rd` duas vezes** (dispatch ou commit no mesmo ciclo): vale o slot
  de maior `k`. No flush, os commits do ciclo são aplicados em ordem por cima
  da restauração.

## Implementação

Cada variante é um módulo independente, sem código compartilhado. `ROBRename`
não tem `ROB_ENTRIES`: o ROB é o próprio banco de renomeação (`ENTRIES`).

`PRFRename.sv` contém o topo e quatro submódulos:

| Submódulo | Função |
|---|---|
| `PRFFreeList` | fila circular das tags livres; até `W` pops e `W` pushes por ciclo; no flush, `head` volta a `tail` |
| `PRFMapTable` | `x0..x31 -> tag` especulativo; fornece `src*_tag` e `old_tag` |
| `PRFCommittedTable` | `x0..x31 -> tag` arquitetural; restaura a map table no flush |
| `PRFRegFile` | `value[]` e `state[]` por tag (`FREE`, `RB_NOT_VALID`, `RB_VALID`, `AR`) |

Para verificar (hoje só `PRFRename` está em `rtl/rename/`):

```sh
make test T="PRFRename PRFRenameBundle"
```

`PRFRename_tb` usa `W = 1`; `PRFRenameBundle_tb` usa `W = 3` e `WB_N = 2`.
