# Completion

Recebe as respostas das quatro fontes de resultado (ALU, Branch Unit, AGU e
dado do load vindo do Memory) e, no mesmo ciclo, faz duas coisas: escreve os
resultados que têm destino no banco físico, anunciando a tag às estações de
reserva (3 barramentos de write-back), e avisa o ROB das instruções que
terminaram (4 portas de resposta). A Completion é **fora de ordem**: as
respostas chegam na ordem em que as fontes terminam, e quem restaura a ordem
de programa é o Retirement. Concluir não é retirar: a instrução ainda pode ser
descartada até o commit.

O livro usa outros nomes para os mesmos eventos (Shen & Lipasti, 4.3.5): o que
este projeto chama de Completion o livro chama de *finish*, e o que chamamos de
Retirement ele chama de *complete*. Por isso o "completion buffer" do livro
(Fig. 5.26) é o nosso ROB, e não esta etapa.

## Vizinhos

| Vizinho | Entrega à Completion | Recebe da Completion |
|---|---|---|
| ALU | `alu_resp_valid`, `alu_resp` | `alu_resp_ready` |
| Branch Unit | `br_resp_valid`, `br_resp` | `br_resp_ready` |
| AGU | `agu_resp_valid`, `agu_resp`; `agu_is_load` (saída `resp_is_load` da `agu`, item 1) | `agu_resp_ready` |
| Memory (dado do load) | `lsu_resp_valid`, `lsu_resp` | `lsu_resp_ready` |
| Rename (`PRFRename`, com `WB_N = 3`) | — | `wb_valid`, `wb_tag`, `wb_data` |
| RS INT e RS MEM (com `WB_N = 3`) | — | `wb_valid`, `wb_tag` |
| ROB (`retire_team`) | `flush` | `rob_resp_valid`, `rob_resp` (entradas `resp_valid`, `resp`) |

A Completion não compara tags (é o wakeup das RS), não guarda o estado das
tags (é o `PRFRegFile`), não marca a instrução como terminada (é o ROB, a
partir da resposta) e não trata a predição errada: o `redirect_t` vai da
Branch Unit direto à entrada `redirect` do `retire_team`.

## Parâmetros

Não tem parâmetros. As duas contagens são fixas e aparecem como `localparam`:

| Constante | Valor | Observação |
|---|---|---|
| `WB_N` | 3 | quem **escreve registrador**: ALU, Branch Unit, load; o `PRFRename` e as RS precisam ser instanciados com o mesmo valor |
| `ROB_N` | 4 | quem **termina instrução**: ALU, Branch Unit, AGU, load; o `retire_team` exige 4 (`ERROR_WB_N_MUST_BE_4`) |

`XLEN`, `TAG_W` e `AGE_W` vêm do `execute_pkg`.

## Interface

| Porta | Direção | Largura | Significado |
|---|---|---|---|
| `clk`, `reset` | entrada | 1 | não usadas: o bloco é combinacional (mesma convenção do `dispatch`) |
| `flush` | entrada | 1 | saída `flush` do ROB; com 1, nenhuma resposta deste ciclo produz efeito |
| `alu_resp_valid`, `alu_resp_ready`, `alu_resp` | entrada, saída, entrada | 1, 1, `fu_resp_t` | resposta da ALU |
| `br_resp_valid`, `br_resp_ready`, `br_resp` | entrada, saída, entrada | 1, 1, `fu_resp_t` | resposta da Branch Unit |
| `agu_resp_valid`, `agu_resp_ready`, `agu_resp` | entrada, saída, entrada | 1, 1, `fu_resp_t` | resposta da AGU |
| `agu_is_load` | entrada | 1 | a resposta da AGU é de um load; vale com `agu_resp_valid` |
| `lsu_resp_valid`, `lsu_resp_ready`, `lsu_resp` | entrada, saída, entrada | 1, 1, `fu_resp_t` | dado do load, vindo do Memory |
| `wb_valid` | saída | `WB_N` | escreve `wb_data` na tag `wb_tag` (`PRFRename`) e acorda quem espera a tag (RS) |
| `wb_tag` | saída | `WB_N` × `TAG_W` | tag física do destino; vale com `wb_valid` |
| `wb_data` | saída | `WB_N` × `XLEN` | resultado; vale com `wb_valid`; as RS ignoram (guardam só tags) |
| `rob_resp_valid` | saída | `ROB_N` | a instrução da porta `p` terminou (ou gerou exceção) |
| `rob_resp` | saída | `ROB_N` × `fu_resp_t` | a resposta da fonte, sem alteração; vale com `rob_resp_valid` |

## Ligação

A mesma tabela do `rtl/issue/README.md`:

| Origem | Barramento de write-back (RS e `PRFRename`) | Porta do ROB |
|---|---|---|
| ALU | 0 | 0 |
| Branch Unit | 1 (link do `jalr`) | 1 |
| AGU | — (o resultado é um endereço) | 2, **só stores e exceções** |
| Load (Memory) | 2 | 3 |

## Regras

```
wb_valid[p]       = src_valid && !flush && wr_en && dst_tag != 0 && !exception
                    (p = 0 ALU, 1 Branch Unit, 2 load)
rob_resp_valid[0] = !flush && alu_resp_valid
rob_resp_valid[1] = !flush && br_resp_valid
rob_resp_valid[2] = !flush && agu_resp_valid && (!agu_is_load || exception)
rob_resp_valid[3] = !flush && lsu_resp_valid
*_resp_ready      = 1
```

- `wb_tag[p] = dst_tag` e `wb_data[p] = result` da fonte do barramento `p`;
  `rob_resp[p]` é a resposta inteira da fonte da porta `p`, sem alteração.
- `*_resp_ready` é sempre 1: o `PRFRename` e o ROB não têm `ready`, e cada
  fonte tem o seu barramento, então não há o que esperar. No ciclo do flush a
  resposta também é consumida, e descartada.
- Toda instrução que termina responde ao ROB, inclusive as sem destino
  (desvios condicionais e stores). Só as com destino escrevem e acordam.
- Nada é reordenado ou juntado. Duas respostas do mesmo ciclo nunca têm a
  mesma tag de destino (cada tag tem um único escritor).
- Sem `*_resp_valid`, nada sai daquela fonte, qualquer que seja o conteúdo.

A regra de write-back do `rtl/issue/README.md` é `resp_valid && wr_en`. A
desta especificação é mais estrita (tag 0, exceção e flush; casos difíceis 3
a 5) e produz o mesmo resultado em toda execução correta (item 8).

## Temporização

O bloco é combinacional: o registrador de fim de estágio já está na saída de
cada FU. Um `add` (tag `T`) seguido de um `sub` que depende dele:

| Ciclo | ALU | Completion | Rename (PRF) | RS | ROB |
|---|---|---|---|---|---|
| t0 | captura o `add` na borda | — | — | `add` emitido | — |
| t1 | `resp_valid = 1`, `dst_tag = T` | `wb_valid[0] = 1`; `rob_resp_valid[0] = 1` | grava `value[T]` na borda | fonte do `sub` fica pronta na borda | marca o `add` como terminado |
| t2 | — | — | `T` em `RB_VALID` | `sub` selecionado; lê `value[T]` | — |

Um load passa pela memória de dados síncrona e termina um ciclo depois:

| Ciclo | AGU | Memory | Completion |
|---|---|---|---|
| t1 | endereço, `agu_is_load = 1` | recebe o endereço na borda | **nada**: nem write-back, nem ROB |
| t2 | — | entrega o dado | `wb_valid[2] = 1`; `rob_resp_valid[3] = 1` |

## Casos difíceis

1. **Desvio condicional.** Chega com `wr_en = 0` e um `dst_tag` sem
   significado. Não pode gerar `wb_valid` (acordaria quem espera aquela tag),
   mas precisa responder ao ROB, senão o ROB nunca o retira.
2. **Load na AGU.** A AGU não responde ao ROB por um load sem exceção: o ROB
   marcaria o load como terminado antes de o dado voltar, e ele seria
   efetivado com o registrador ainda sem valor. O load termina pela porta 3.
   A Completion não consegue distinguir load de store pelo `wr_en`: um load
   para `x0` chega com `wr_en = 0`, como um store, e responderia ao ROB pela
   porta 2 e de novo pela porta 3. Por isso existe a entrada `agu_is_load`.
3. **Exceção.** Uma instrução com `exception = 1` não escreve nem acorda,
   mesmo com `wr_en = 1`: o resultado não tem significado, e a exceção
   descarta as mais novas quando chegar ao topo do ROB. A resposta vai ao ROB
   com a causa; o `retire_team` a transforma em exceção da entrada (portas 1,
   2 e 3; a ALU não gera exceções).
4. **Tag 0.** É a tag de `x0` e nunca é alocada. Um resultado com `wr_en = 1`
   e `dst_tag = 0` é erro da fonte (o Decode entrega `wr_en = 0` para
   `rd = x0`); a Completion não o anuncia. A resposta ao ROB sai normalmente.
5. **Flush no mesmo ciclo.** Com `flush = 1`, nada sai. O flush é total e
   disparado pelo ROB: a instrução culpada está no topo e já terminou, então
   toda resposta que chega neste ciclo é de uma instrução mais nova, que deve
   morrer. O `PRFRegFile` já ignora o write-back no ciclo do flush; a regra
   vale também para as RS e o ROB.
6. **Reuso de tag depois do flush.** Uma tag pode ser realocada logo depois
   do flush. A Completion não distingue uma resposta atrasada de uma
   instrução descartada: cabe a cada fonte não entregá-la. A ALU e a AGU já
   fazem isso (`flush_age`); a Branch Unit e o Memory precisam fazer o mesmo,
   incluindo, no Memory, a leitura que já entrou na memória síncrona.
7. **Predição errada.** A Branch Unit manda o `redirect_t` direto ao ROB e,
   para o mesmo desvio, a resposta normal pela porta 1. A Completion repassa
   a resposta sem tratamento especial; o `retire_team` dá prioridade ao
   `redirect` quando os dois têm o mesmo `age`.

## Casos de teste obrigatórios

Em `tb/unit/completion_tb.sv`. A interface é fixa, então não há
`PARAMS_completion` no Makefile. Imprime `PASS` no fim e chama `$fatal` em
qualquer verificação que falhe. Como o bloco é combinacional, cada verificação
é feita no mesmo ciclo em que as entradas são aplicadas. Os casos dirigidos
comparam com os vetores esperados escritos à mão (quais barramentos e quais
portas do ROB ligam); o caso R compara com as regras.

- **T1:** Sem respostas, com e sem reset: nenhuma saída válida; todos os `*_resp_ready` em 1.
- **T2:** ALU com destino: barramento 0 e porta 0.
- **T3:** Branch Unit: `jalr` no barramento 1 e porta 1; desvio condicional só na porta 1.
- **T4:** AGU com store: só a porta 2, nunca write-back.
- **T5:** AGU com load sem exceção, inclusive load para `x0`: nada sai.
- **T6:** AGU com load desalinhado: porta 2, com a causa.
- **T7:** AGU com store desalinhado: porta 2.
- **T8:** Dado do load: barramento 2 e porta 3.
- **T9:** Exceção com `wr_en = 1`: só a porta do ROB, sem write-back.
- **T10:** `wr_en = 1` com tag 0 em cada fonte que escreve: só as portas do ROB.
- **T11:** As quatro fontes no mesmo ciclo, com conteúdos distintos (pega troca de barramentos ou portas); de novo com a AGU num load.
- **T12:** Sem `valid`, com conteúdo que escreveria e com conteúdo `X`: nada sai.
- **T13:** Flush com as quatro fontes válidas: nada sai; todos prontos.
- **T14:** Reuso de tag no ciclo seguinte ao flush: as mesmas tags, com dados novos, são escritas.
- **T15:** Valores-limite: bit 63, metade de cima, maior tag, `age` 0 e máximo, todas as causas.
- **R:** 3000 ciclos aleatórios, com flush aleatório, contra as regras.

Integração: o `tb/integration/backend_tb.sv` (PR #22) liga os barramentos e
as respostas ao ROB à mão. Trocando essa ligação por uma instância da
Completion, o programa de 42 instruções é efetivado nos mesmos 51 e 52 ciclos
(`DEEP2 = 0` e `1`) da ligação original. Proposta: fazer essa troca no
`backend_tb` depois que os dois PRs entrarem no `main`.

## Síntese (sky130, 25 ns)

Medida com o LibreLane 3.0.17, no fluxo completo (síntese,
posicionamento e roteamento, até o GDS), com `USE_SLANG`,
`SYNTH_ABC_BUFFERING`, relógio de 25 ns e o SDC genérico (5 ns de atraso
externo na entrada e na saída). Bloco de 400 x 400 µm (`DIE_AREA`), por causa
dos ~900 pinos. O `config.json` utilizado:

```json
{
  "DESIGN_NAME": "completion",
  "VERILOG_FILES": ["dir::../../rtl/execute/execute_pkg.sv",
                    "dir::../../rtl/completion/completion.sv"],
  "USE_SLANG": true,
  "CLOCK_PORT": "clk",
  "CLOCK_PERIOD": 25,
  "SYNTH_ABC_BUFFERING": true,
  "FP_SIZING": "absolute",
  "DIE_AREA": [0, 0, 400, 400],
  "PL_TARGET_DENSITY_PCT": 40,
  "RUN_KLAYOUT_XOR": false
}
```

| Células | Área das células | Setup (pior canto) | Hold | DRC, LVS, antena |
|---|---|---|---|---|
| 1.155 | 8.765 µm² | +10,76 ns (`max_ss_100C_1v60`) | +10,07 ns | passam |

Células e área sem as de preenchimento, de tap e os diodos de antena (com tap
e antena: 3.323 células e 11.544 µm²). Das 1.155, só 19 são lógica (17 portas
de várias entradas e 2 inversores); as outras 1.136 são buffers: 549 nos
pinos e 587 inseridos para corrigir tempo de transição. A Completion é quase
só fios: a lógica ocupa 179 µm², e o bloco usa 7,9% da área, que é ditada
pelos pinos.

A Completion é combinacional: só há caminhos de entrada para saída. Dos
14,75 ns que sobram entre os atrasos externos e a incerteza do relógio
(0,25 ns), ela usa cerca de 4,0 ns no pior canto. O caminho mais lento é o
cálculo do `wb_valid` do barramento 0:

```
alu_resp.dst_tag[3] → buffer de entrada → or4 (bits da tag) → o31a (tag != 0, e o resto da condição) → buffer de saída → wb_valid[0]
```

São duas portas lógicas, que somam 2,0 ns; os buffers dos pinos somam o resto
(1,9 ns). O barramento 2 (load) tem o mesmo caminho, com folga de +10,89 ns.
Sobram 37 avisos de tempo de transição no canto `max_ss_100C_1v60` (24 no
`min_ss_100C_1v60`), nos fios que saem dos buffers de entrada: cada bit da tag
atravessa o bloco até três destinos (`wb_tag`, `rob_resp` e a porta lógica),
e no fio de `alu_resp[17]` a transição chega a 0,83 ns. Dentro do `core`,
esses sinais viram fios internos curtos.

## Versões

| Versão | Conteúdo | Depende de |
|---|---|---|
| v1 | Esta especificação: 4 fontes, 3 barramentos, 4 portas do ROB, combinacional, flush total | — |
| v2 | `agu_is_load` ligado à origem definitiva; porta do Memory no formato definitivo | itens 3 e 6 |

## Pontos em aberto

**Interface com os vizinhos**

1. **Origem do `agu_is_load`. Decidido: (A).** A resposta da AGU não diz se
   é de um load, e o `wr_en` não serve (caso difícil 2). Opções: (A) a AGU
   ganha uma saída `resp_is_load`, que ela já calcula por dentro; (B) o
   Memory, que recebe a resposta da AGU, fornece o sinal; (C) um campo novo
   no `fu_resp_t`, que muda o `execute_pkg` e todos os blocos. Adotada a (A):
   a `agu` tem a saída `resp_is_load`, e o `core` (`rtl/core/core.sv`) a liga
   em `agu_is_load`. O `backend_tb` ainda usa a tabela indexada pelo `age`,
   que o modelo do LSU precisa de qualquer forma para saber o tamanho do
   acesso.
2. **Retorno do load.** O Memory não tem especificação. Proposta: a mesma
   `fu_resp_t`, como no modelo do `backend_tb`, com três requisitos para o
   Memory: os metadados (`dst_tag`, `wr_en`, `age`) andam em paralelo à
   leitura síncrona e chegam no mesmo ciclo que o dado; o `result` já vem com
   a extensão de sinal ou de zeros do tipo do load; a leitura em voo no
   flush é descartada (caso difícil 6). Como `lsu_resp_ready` é sempre 1, o
   Memory nunca precisa guardar um dado recusado.

**Comportamento**

3. **Regra de write-back mais estrita que a do `rtl/issue/README.md`.** Tag 0,
   exceção e flush (casos difíceis 3 a 5) não estão na fórmula
   `resp_valid && wr_en`. Proposta: acrescentar ao README do Issue (aval da
   Maria Ingrid).
4. **Combinacional.** Proposta desta especificação. Um estágio registrado
   próprio encurtaria o caminho até os comparadores das RS, mas soma um ciclo
   a todo wakeup, e o Issue precisaria saber.

## Referências

- Shen & Lipasti, *Modern Processor Design*: 4.3.5 (finish, complete e
  retire, p. 206–207), 5.2.5 (barramento de encaminhamento e escrita no banco
  de renomeação, p. 256), 5.2.6 (ROB, Fig. 5.28).