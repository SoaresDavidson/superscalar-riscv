# Estações de reserva (RS)

> Rascunho de especificação, a ser revisado pela equipe e movido para a página
> [[Issue]] da wiki. Os itens em [Pontos em aberto](#pontos-em-aberto) não
> estão decididos.

As RS guardam as instruções que o dispatch aceitou até que os operandos fiquem
prontos e a unidade funcional esteja livre, e então as emitem para execução.
Referência: Shen & Lipasti, seção 5.2.6 (dispatching, waiting e issuing).

## Organização

O Execute tem **uma FU de cada tipo** (decisão da reunião, página Execute):
uma ALU, uma Branch Unit e uma AGU. Há duas RS, no modelo de estações
agrupadas (*clustered*) do livro:

| RS | Entradas | Alimenta | Instruções (`fu_of(op)`) |
|---|---|---|---|
| RS INT | `RS_INT_ENTRIES` = 8 | ALU e Branch Unit | `FU_ALU`, `FU_BRANCH` |
| RS MEM | `RS_MEM_ENTRIES` = 4 | AGU | `FU_AGU` |

A FU de cada entrada é `fu_of(op)`: uma instrução tem um único destino
possível, e não há escolha de porta. Os tamanhos são propostas (parâmetros).

O formato das entradas (`rs_int_entry_t`, `rs_mem_entry_t`) está em
`rtl/dispatch/dispatch_pkg.sv` e é descrito em `docs/dispatch/Dispatch.md`,
seção "Entrada na RS".

## Vizinhos

| Vizinho | Entrega à RS | Recebe da RS |
|---|---|---|
| Dispatch | por slot: bit de escrita (`int_wr`, `mem_wr`) e a entrada montada | `int_free`, `mem_free` |
| Barramentos de resultado (CDB) | `WB_N` = 3 portas: `cdb_valid`, `cdb_tag` | nada |
| Rename (`PRFRename`) | `read_valid`, `read_data` | `read_tag`: 6 portas, 2 por FU |
| ALU, Branch Unit, AGU | `req_ready` | `req_valid` e `req` (`fu_req_t`) |
| Controle | `flush` | nada |

Os 3 barramentos são as portas de write-back do banco físico (página
Execute): ALU, Branch Unit (link do `jalr`) e retorno do load, vindo do
Memory. A AGU não escreve. Os mesmos sinais chegam às portas `wb_*` do
`PRFRename`.

O handshake com cada FU é o do `alu.sv`: a transferência acontece na borda em
que `req_valid` e `req_ready` estão em 1.

As RS guardam **só tags** (item 4 do `Dispatch.md`, decidido): nenhuma
entrada guarda valores. Os valores são lidos do banco físico na emissão,
pelas portas `read_tag -> read_valid, read_data` do `PRFRename` (commit
`a825634`, branch `davi#rename`). Portas usadas: 0 e 1 pela ALU, 2 e 3 pela
Branch Unit, 4 e 5 pela AGU.

## Funcionamento

Cada RS tem cinco partes. As escritas no estado (`busy` e campos das entradas)
acontecem na borda do relógio.

### 1. Alocação

- O dispatch indica, por slot `k`, se há uma instrução para esta RS
  (`int_wr[k]`) e qual é (`int_entry[k]`).
- A **k-ésima instrução** do bundle que vai para esta RS fica com a
  **k-ésima entrada livre**, procurando a partir da entrada 0. A posição do
  slot no bundle não importa, só a ordem entre as instruções desta RS.
- Em hardware: `W` codificadores de prioridade em cadeia; cada um acha a
  primeira entrada livre que os anteriores ainda não reservaram.
- Só são usadas entradas livres no **começo** do ciclo: uma entrada liberada
  por uma emissão no mesmo ciclo só é reaproveitada no ciclo seguinte.
- O dispatch garante que nunca chegam mais instruções do que entradas livres
  (`int_free >= n_int`).

### 2. Wakeup

- A cada ciclo, toda fonte com `ready = 0` de toda entrada ocupada compara a
  sua tag com as `WB_N` tags dos barramentos com `cdb_valid = 1`. Havendo
  coincidência, a fonte passa a `ready = 1` na borda. Nenhum valor é copiado:
  ele já foi escrito no banco por esse mesmo write-back.
- As duas fontes de uma entrada podem acordar no mesmo ciclo, por barramentos
  diferentes.
- **Entrada escrita no mesmo ciclo de um anúncio:** as fontes da entrada que
  está sendo escrita também são comparadas com os barramentos daquele ciclo.
  Nesta versão isso é redundante, porque o `PRFRename` já repassa ao dispatch
  um write-back do mesmo ciclo (bypass) e a fonte chega com `ready = 1`. A
  comparação fica como proteção, e passa a ser necessária se o anúncio for
  antecipado para antes do write-back.

### 3. Seleção e emissão

- **RS INT:** dois seletores independentes. O da ALU só considera entradas com
  `fu_of(op) == FU_ALU`; o da Branch Unit só considera `FU_BRANCH`. Como
  disputam conjuntos disjuntos de entradas, não há cascata.
- **RS MEM:** um seletor, para a AGU.
- Uma entrada está **pronta** quando `busy && src1_ready && src2_ready`, com os
  bits de pronto do começo do ciclo. Uma fonte que acorda num ciclo só pode
  ser emitida no ciclo seguinte.
- Política: entre as prontas, a de **menor índice**. Quando houver `age`, passa
  a ser a **mais antiga** (item 3).
- O seletor só emite se a FU estiver livre (`req_ready = 1`). Na transferência,
  a entrada volta a `busy = 0`.
- **Leitura dos operandos:** no ciclo da emissão, as tags das fontes da
  entrada escolhida vão para as `read_tag` da FU, e `src1` e `src2` do
  `fu_req_t` vêm de `read_data`. A leitura é combinacional, então seleção,
  leitura e montagem do `fu_req_t` cabem no mesmo ciclo, e a FU captura a
  requisição na borda. Como a entrada só é emitida no ciclo seguinte ao
  wakeup, o valor já está gravado no banco; `read_valid` deve sair sempre 1
  (o testbench confere). Uma fonte que a instrução não usa tem tag 0 (`x0`),
  que lê 0.
- A emissão monta o `fu_req_t` a partir da entrada: `src1` e `src2` vêm da
  leitura acima; os demais campos (`op`, `imm`, `use_imm`, `pc`,
  `dst_tag`, `wr_en`, `age`, `pred_taken`, `pred_target`) são copiados. Na RS
  MEM, os campos que a entrada não tem (`use_imm`, `pc`, `pred_*`) vão em zero;
  a AGU ignora `use_imm` (página Execute).

### 4. Contagem de livres

- `int_free` (e `mem_free`) é o número de entradas com `busy = 0` no **começo**
  do ciclo. Não inclui as entradas que serão liberadas por emissões do mesmo
  ciclo: isso pouparia um ciclo, mas penduraria o dispatch e o Rename no fim
  do caminho de wakeup e seleção, o mais lento da RS.

### 5. Reset e flush

- Com `reset`, todas as entradas ficam com `busy = 0`.
- Com `flush`, todas as entradas ficam com `busy = 0` na borda. Isso vale para
  o flush no commit, o único que o `PRFRename` suporta hoje: o desvio mal
  previsto está no topo do ROB, então toda instrução ainda na RS é mais nova
  que ele e está no caminho errado. No mesmo ciclo, o dispatch não aceita
  nada (`accept = 0`). Com flush seletivo, a regra muda (item 6).

## Casos para o testbench

1. Alocação com entradas livres espalhadas, inclusive quando a 2ª instrução do
   bundle para esta RS não está no slot 1.
2. RS cheia: `int_free = 0` e nenhuma escrita.
3. Wakeup de uma fonte, das duas fontes pelo mesmo barramento e por
   barramentos diferentes, e de várias entradas pelo mesmo anúncio.
4. Anúncio no mesmo ciclo da escrita da entrada.
5. Seleção: duas entradas prontas para a mesma FU (sai a de menor índice);
   prontas para FUs diferentes (as duas saem no mesmo ciclo).
6. Back-pressure: `req_ready = 0` segura a entrada pronta, sem perdê-la nem
   duplicá-la.
7. Entrada liberada e reocupada: não é reaproveitada no mesmo ciclo.
8. Flush com entradas ocupadas, prontas e esperando; e flush no mesmo ciclo de
   uma escrita do dispatch.
9. Reuso de tag depois do flush: um anúncio antigo não pode acordar uma
   entrada nova.

## Pontos em aberto

1. **`age` e seleção pela mais antiga** (item 3 do `Dispatch.md`). Sem o
   `age`, a seleção é pela posição na RS, e uma instrução antiga numa entrada
   de índice alto pode esperar mais do que devia.
2. ~~**RS com valores ou só tags**~~ **Resolvido (14/11): só tags.** A
   leitura dos valores é feita na emissão, pelas portas de leitura do
   `PRFRename`. Em aberto dentro disso: se a leitura passar a ser um estágio
   próprio (registrado) para encurtar o ciclo, a FU recebe a requisição um
   ciclo depois, e o wakeup precisa ser revisto.
3. **Modelo de flush** (item 6 do `Dispatch.md`). Com flush seletivo, a RS
   recebe `flush_age` e zera só as entradas mais novas que ele (usando
   `age_is_younger`), o que depende do item 1.
4. **Ordem na RS MEM.** Sem uma fila de loads e stores, um load não pode
   passar à frente de um store mais antigo ao mesmo endereço, e a seleção
   pela posição não respeita a ordem do programa. Proposta para a primeira
   versão: a RS MEM emite **em ordem de programa**, como a fila de endereços
   do R10000, o que exige o `age` (item 1) ou uma alocação circular, em
   ordem. Depende da parte de memória (Shen & Lipasti, 5.3).
5. **Emissão do store** (item 7 do `Dispatch.md`). Proposta: o store só sai
   com as duas fontes prontas (base e dado).
6. **Responsável.** Não há issue para a etapa de Issue; registrar quem faz as
   RS.
