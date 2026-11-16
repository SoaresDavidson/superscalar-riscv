# Fetch

> Rascunho de especificação, a ser revisado pela equipe e movido para a wiki.
> Baseado no `execute_pkg` e no Decode do branch `matheus#decode` (07/11).

Primeiro estágio do pipeline. A cada ciclo, lê da memória de instruções um
bundle de `WIDTH` instruções consecutivas (PC, PC+4, PC+8 com `WIDTH = 3`),
entrega ao Decode com o PC de cada uma e escolhe o PC do ciclo seguinte. O
Fetch é **em ordem**: só a execução sai de ordem.

Esta especificação descreve a v2: a memória de instruções é **síncrona** (a
instrução chega um ciclo depois do endereço), então o Fetch tem dois estágios,
F1 e F2. Ainda não há predição de desvios: todo desvio condicional é buscado
como não tomado, e o `JAL` é resolvido pelo Decode (decisão 7). A predição
entra na v3 (ver [Versões](#versões)).

## Vizinhos

| Vizinho | Entrega ao Fetch | Recebe do Fetch |
|---|---|---|
| Memória de instruções | `WIDTH` instruções de 32 bits | `WIDTH` endereços |
| Decode | `in_ready`; `redirect_valid` e `redirect_pc` (`JAL`) | bundle: `in_valid`, `in_slot_valid`, `in_inst`, `in_pc` |
| Pipeline-Control | redirect do back end (desvio mal previsto, exceção), já escolhido entre as fontes | — |

## Parâmetros

| Parâmetro | Padrão | Observação |
|---|---|---|
| `WIDTH` | 3 | instruções por ciclo (decisão 2); nunca um 3 literal no RTL |
| `RESET_PC` | `0` | PC depois do reset; valor ainda não decidido (item 6) |

`XLEN` vem do `execute_pkg`, como no Decode: o PC é `xlen_t` lá, e um `XLEN`
próprio do módulo poderia divergir dele sem erro. A instrução tem sempre 32
bits (decisão 1: RV64I, sem extensão C).

## Interface

As saídas para o Decode têm os mesmos nomes das entradas `in_*` dele.

| Porta | Direção | Largura | Significado |
|---|---|---|---|
| `clk` | entrada | 1 | — |
| `reset` | entrada | 1 | síncrono, ativo em alto; PC vai para `RESET_PC` e `out_valid = 0` |
| `imem_addr` | saída | `WIDTH` × `XLEN` | endereço de cada slot: `pc + 4k`, com o `pc` de F1 |
| `imem_rdata` | entrada | `WIDTH` × 32 | instrução do endereço enviado no ciclo **anterior** (memória síncrona) |
| `out_valid` | saída | 1 | há um bundle para o Decode (`decode.in_valid`) |
| `out_ready` | entrada | 1 | o Decode aceita (`decode.in_ready`); a transferência acontece quando os dois estão em 1 |
| `out_slot_valid` | saída | `WIDTH` | slots válidos, zeros à direita (`decode.in_slot_valid`); todos em 1 na v1 |
| `out_inst` | saída | `WIDTH` × 32 | instruções, slot 0 primeiro em ordem de programa (`decode.in_inst`) |
| `out_pc` | saída | `WIDTH` × `XLEN` | PC de cada slot (`decode.in_pc`) |
| `dec_redirect_valid`, `dec_redirect_pc` | entrada | 1 + `XLEN` | `decode.redirect_valid` e `decode.redirect_pc` (`JAL`) |
| `be_redirect_valid`, `be_redirect_pc` | entrada | 1 + `XLEN` | redirect do back end, vindo do Pipeline-Control |

## Memória de instruções

A memória é síncrona, com 1 ciclo de latência: o valor em `imem_rdata[k]` num
ciclo é a instrução do endereço que estava em `imem_addr[k]` no ciclo anterior.
Há uma porta de leitura por slot. A memória não precisa de enable: o Fetch não
pede para ela segurar a saída, ele mesmo guarda o que precisa.

## Estágios

| Estágio | O que acontece | Registradores |
|---|---|---|
| F1 | envia o endereço do próximo bundle (`imem_addr = pc + 4k`) | `pc` |
| F2 | recebe as instruções e oferece o bundle ao Decode | PC do bundle, `valid` de F2, instruções guardadas no stall |

Num stall, a memória já está entregando o bundle seguinte, então o bundle
parado em F2 perde as instruções se ninguém as guardar. No primeiro ciclo de
stall o Fetch copia `imem_rdata` para um registrador próprio e passa a usá-lo
até o bundle ser aceito. Custo: `WIDTH × 32` flip-flops (96 com `WIDTH = 3`).

## Próximo estado

Na borda do relógio, nesta prioridade:

| Prioridade | Condição | `pc` (F1) | F2 |
|---|---|---|---|
| 1 | `reset` | `RESET_PC` | vazio |
| 2 | `be_redirect_valid` | `be_redirect_pc` | vazio |
| 3 | `dec_redirect_valid` | `dec_redirect_pc` | vazio |
| 4 | F2 com bundle e `out_ready = 0` (stall) | não muda | mantém o bundle e as instruções |
| 5 | caso normal (F2 vazio, ou bundle aceito) | `pc + 4 × WIDTH` | recebe o bundle que estava em F1 |

Depois de um reset ou de um redirect, F2 fica vazio por um ciclo: o endereço
novo acabou de ser enviado e a instrução ainda não chegou.

O back end vence o Decode porque um redirect do back end corrige uma
instrução mais antiga: o `JAL` que o Decode está resolvendo pode estar ele
mesmo no caminho errado.

```
out_valid = !reset && f2_valid && !be_redirect_valid && !dec_redirect_valid
```

No ciclo de um redirect, o bundle em F2 foi buscado pelo PC antigo e está no
caminho errado. Baixar `out_valid` impede que o Decode o aceite. O bundle que
estava em F1 também é do caminho errado e é descartado na mesma borda.

## Interação com o Decode no `JAL`

O Decode levanta `redirect_valid` (um pulso de um ciclo) no ciclo **seguinte**
ao que aceitou o bundle com o `JAL`. Exemplo com `jal` em `0x10`, alvo `0x40`:

| Ciclo | F1 envia | F2 oferece | `out_valid` | Decode aceita | Redirect do Decode |
|---|---|---|---|---|---|
| 1 | `0x0C` | `0x00`–`0x08` | 1 | sim | — |
| 2 | `0x18` | `0x0C`–`0x14` (tem o `jal`) | 1 | sim | — |
| 3 | `0x24` | `0x18`–`0x20` (caminho errado) | 0 | não | 1, alvo `0x40` |
| 4 | `0x40` | vazio | 0 | não | — |
| 5 | `0x4C` | `0x40`–`0x48` | 1 | sim | — |

O caminho errado é eliminado em três lugares:

- dentro do bundle do `jal`, o Decode mata os slots à direita do salto
  (`out_slot_kill`);
- o bundle em F2 no ciclo do redirect não é oferecido (ciclo 3);
- o bundle em F1 nesse ciclo (`0x24`) é descartado na borda.

Custo: 2 ciclos de bolha por `JAL` (era 1 com memória combinacional).

## Casos de teste obrigatórios

Em `tb/unit/fetch_tb.sv`, com `WIDTH` de 1 a 4 (`PARAMS_fetch` no Makefile).
Imprime `PASS` no fim e chama `$fatal` em qualquer verificação que falhe.
Os nomes T1 a T11 são os usados nas mensagens de erro do testbench e nos
commits.

- **T1:** Durante o reset, `out_valid = 0`.
- **T2:** Depois do reset, `out_valid = 0` por um ciclo (a memória ainda está lendo); no seguinte, o bundle começa em `RESET_PC`, com os `WIDTH` slots válidos.
- **T3:** Busca sequencial: `pc`, `pc + 4W`, `pc + 8W`.
- **T4:** Stall: com `out_ready = 0` por vários ciclos, o PC e as instruções do bundle não mudam, embora a memória já esteja entregando o bundle seguinte; quando `out_ready` volta, o próximo bundle sai sem pular nem repetir nenhum.
- **T5:** Redirect do Decode: `out_valid = 0` no ciclo do redirect e no seguinte (bundle em voo descartado); o próximo começa no alvo.
- **T6:** Redirect do back end durante um stall: o redirect vence, e as instruções guardadas no stall não aparecem no bundle do alvo.
- **T7:** Dois redirects no mesmo ciclo: vence o back end.
- **T8:** Alvo que não é múltiplo de `4W`: o bundle começa exatamente no alvo.
- **T9:** PC acima de 4 GB (PC de 64 bits).
- **T10:** Reset no meio da execução: volta a `RESET_PC`.

Em `tb/integration/fetch_decode_tb.sv` (Fetch + Decode real, com o redirect
do `JAL` ligado):

- **T11:** Programa com `jal` no slot 1 e no slot 0 de bundles diferentes e
  back-pressure aleatória na saída do Decode: as instruções que saem do
  Decode seguem exatamente a ordem do programa, e nenhuma do caminho errado
  passa.

## Versões

| Versão | Conteúdo | Depende de |
|---|---|---|
| v1 | Esta especificação | — |
| v2 | Memória síncrona: estágios F1 e F2, instruções guardadas no stall, `JAL` com 2 bolhas. O Fetch Buffer não é do Fetch: é o `PipeFifo` do Davi (#16), entre o Fetch e o Decode | — |
| v3 | Pre-decode do opcode; predição estática (para trás = tomado) e depois contadores de 2 bits; BTB para `jalr` e alvos de branch; slots parciais depois de desvio previsto tomado; porta de atualização do preditor | item 1 e página Branch-Prediction |
| v4 | RAS com a convenção `x1`/`x5` (decisão 7), restaurada no flush | v3 |

## Pontos em aberto

**Interface com os vizinhos**

1. **Caminho da predição.** O `fu_req_t` tem `pred_taken` e `pred_target`
   ("prediction made by Fetch"), mas nem a entrada do Decode nem o `uop_t`
   têm esses campos (é também o item 5 do Dispatch). Proposta: acrescentar
   `in_pred_taken` e `in_pred_target` por slot no Decode e os dois campos no
   `uop_t`. Muda o `execute_pkg`: precisa do aval do Decode e do Execute.
2. **Fetch Buffer.** Proposto pelo Davi no #16 (`PipeFifo`, instância
   `u_ibuf`). Falta o merge e combinar a ligação do `flush` no `JAL`.
3. **Flush coerente com o Decode.** O Decode tem uma entrada `flush` própria.
   O Pipeline-Control precisa levantar o `flush` do Decode no mesmo ciclo do
   `be_redirect_valid` do Fetch; senão um bundle do caminho errado parado no
   Decode segue adiante.

**Comportamento**

4. **Alvo desalinhado.** Sem a extensão C, um alvo que não é múltiplo de 4
   gera exceção na instrução de salto. Proposta: quem calcula o alvo (Branch
   Unit para `jalr` e branches, Decode para `jal`) confere; o Fetch assume
   alvos alinhados.
5. **`fence.i`** (decisão 9). Se entrar no escopo, o Pipeline-Control usa o
   redirect do back end com o PC seguinte ao `fence.i`; o Fetch não precisa
   de porta nova.
6. **`RESET_PC`.** Valor a definir.
7. **Atualização do preditor** (v3). Na resolução do desvio, como no livro
   (Shen & Lipasti, 5.1.4), ou no retire, só com desvios confirmados.

**Alinhamento**

8. **Bundle de 12 bytes.** A decisão 1 fala em bloco alinhado de `4N` bytes,
   mas com `N = 3` são 12 bytes, que não é potência de 2, e um alvo de desvio
   pode cair no meio de um bloco. A v1 usa uma porta de leitura por slot, cada
   uma com o próprio endereço, e não exige alinhamento. Numa memória real isso
   vira bancos intercalados, como no IBM RS/6000 (Shen & Lipasti, 4.3.1).

## Referências

- Shen & Lipasti, *Modern Processor Design*: 4.3.1 (fetch group e
  alinhamento), 5.1.2 a 5.1.4 (custo de desvios, BTB, contadores de 2 bits,
  recuperação), 6.3 (fetch do PowerPC 620).
- Smith & Sohi, *The Microarchitecture of Superscalar Processors*, seção 3.1.
- `rtl/decode/README.md` e a página Decode da wiki, §10 (redirect do `JAL`).
