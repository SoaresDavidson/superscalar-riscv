# `completion` — contrato de interface

Recebe as respostas das cinco fontes de resultado (ALU, Branch Unit, AGU de
load, AGU de store e dado do load vindo do Memory) e, no mesmo ciclo, liga os 3 barramentos de
write-back (`PRFRename` e estações de reserva) e as 4 portas de resposta do ROB
(`retire_team`). É puramente combinacional: o registrador de fim de estágio já
está na saída de cada FU, e as escritas acontecem nos vizinhos, na borda do
relógio.

Especificação: [`docs/completion/Completion.md`](../../docs/completion/Completion.md).
Tipos compartilhados (`fu_resp_t`, `tag_t`, `xlen_t`): `rtl/execute/execute_pkg.sv`.

## Parâmetros

Não tem parâmetros. As duas contagens são fixas:

| Constante | Valor | Significado |
|---|---|---|
| `WB_N` | 3 | barramentos de write-back: quem **escreve registrador** (ALU, Branch Unit, load). O `PRFRename`, o `rs_int` e o `rs_mem` precisam ser instanciados com `WB_N = 3` (o padrão do `PRFRename` é 1) |
| `ROB_N` | 4 | portas de resposta: quem **termina instrução** (ALU, Branch Unit, AGU, load). É o `WB_N = 4` que o `retire_team` exige; as duas AGUs dividem a porta 2 |

## Portas

### Controle

| Porta | Dir. | Significado |
|---|---|---|
| `clk`, `reset` | entrada | não usadas: o bloco é combinacional |
| `flush` | entrada | saída `flush` do `retire_team`; com 1, nenhuma resposta deste ciclo produz efeito |

### Fontes de resultado

Uma fonte por FU, cada uma com o handshake do projeto. Todas as respostas são
`fu_resp_t`.

| Porta | Dir. | Liga em | Significado |
|---|---|---|---|
| `alu_resp_valid`, `alu_resp` | entrada | `resp_valid`, `resp` da `alu` | resposta da ALU |
| `alu_resp_ready` | saída | `resp_ready` da `alu` | sempre 1 |
| `br_resp_valid`, `br_resp` | entrada | Branch Unit (a fazer) | resposta da Branch Unit |
| `br_resp_ready` | saída | Branch Unit | sempre 1 |
| `agu_ld_resp_valid`, `agu_ld_resp` | entrada | `resp_valid`, `resp` da AGU de load | resposta da AGU de load |
| `agu_ld_resp_ready` | saída | `resp_ready` da AGU de load | 0 só quando perde a disputa da porta 2 |
| `agu_st_resp_valid`, `agu_st_resp` | entrada | `resp_valid`, `resp` da AGU de store | resposta da AGU de store |
| `agu_st_resp_ready` | saída | `resp_ready` da AGU de store | 0 só quando perde a disputa da porta 2 |
| `lsu_resp_valid`, `lsu_resp` | entrada | Memory (a fazer) | dado do load, já estendido |
| `lsu_resp_ready` | saída | Memory | sempre 1 |

### Write-back (`PRFRename` e estações de reserva)

| Porta | Dir. | Liga em | Significado |
|---|---|---|---|
| `wb_valid[WB_N]` | saída | `wb_valid` do `PRFRename`, do `rs_int` e do `rs_mem` | há um resultado no barramento `p` |
| `wb_tag[WB_N]` | saída | `wb_tag` dos mesmos três | tag física do destino; vale com `wb_valid` |
| `wb_data[WB_N]` | saída | `wb_data` do `PRFRename` | resultado; vale com `wb_valid`; as RS não o usam |

### ROB (`retire_team`)

| Porta | Dir. | Liga em | Significado |
|---|---|---|---|
| `rob_resp_valid[ROB_N]` | saída | `resp_valid` | a instrução da porta `p` terminou, ou gerou exceção |
| `rob_resp[ROB_N]` | saída | `resp` | a resposta da fonte, sem alteração; vale com `rob_resp_valid` |

O `redirect_t` da Branch Unit **não** passa por aqui: vai direto à entrada
`redirect` do `retire_team`.

## Comportamento

Ligação (a mesma tabela do `rtl/issue/README.md`):

| Origem | Barramento `wb[p]` | Porta do ROB |
|---|---|---|
| ALU | 0 | 0 |
| Branch Unit | 1 | 1 |
| AGU de load | — (o resultado é um endereço) | 2, só com exceção |
| AGU de store | — | 2, todo store |
| Load (Memory) | 2 | 3 |

Regras:

```
wb_valid[p]       = src_valid && !flush && wr_en && dst_tag != 0 && !exception
rob_resp_valid[0] = !flush && alu_resp_valid
rob_resp_valid[1] = !flush && br_resp_valid
rob_resp_valid[2] = !flush && (ld_cand || st_cand)    ld_cand = load com exceção
rob_resp[2]       = a mais antiga das duas candidatas    st_cand = store
rob_resp_valid[3] = !flush && lsu_resp_valid
agu_*_resp_ready  = 0 só para quem perde a disputa da porta 2 (fora do flush)
os outros *_resp_ready = 1
```

Garantias para os vizinhos:

- Um barramento de write-back só liga com destino real: nunca para um desvio
  condicional ou um store (`wr_en = 0`), nunca na tag 0, nunca para uma
  instrução com exceção.
- Toda instrução que termina responde ao ROB uma única vez: as sem destino
  também, e um load só pela porta 3, quando o dado chega (a AGU não responde
  por um load sem exceção).
- `rob_resp` repassa a `fu_resp_t` da fonte sem alterar nenhum campo.
- Sem `*_resp_valid`, nada sai daquela fonte, qualquer que seja o conteúdo.
- Com `flush = 1`, nada é escrito e nada é respondido ao ROB.
- Só a disputa da porta 2 segura uma fonte: quando um store e um load com
  exceção chegam no mesmo ciclo, sai o mais antigo, e a AGU do outro recebe
  `resp_ready = 0` e o entrega no ciclo seguinte. Um load sem exceção nunca é
  segurado. No ciclo do flush todos os `*_resp_ready` ficam em 1 (a resposta
  é consumida e descartada).

O que fica com as fontes: não entregar, depois do flush, a resposta de uma
instrução descartada (a tag pode já ter sido realocada). A ALU e a AGU já
fazem isso com `flush_age`.

## Pendências

Ver `docs/completion/Completion.md`, "Pontos em aberto". As que mudam esta
interface ou a ligação:

- **Porta do Memory** (item 6): `lsu_*` supõe a mesma `fu_resp_t`, como no
  modelo do `backend_tb`. O Memory não tem especificação.
- **Regra de write-back** (item 8): a do `rtl/issue/README.md` é
  `resp_valid && wr_en`; a desta interface também bloqueia tag 0, exceção e
  flush. O resultado é o mesmo em toda execução correta.

## Teste

`tb/unit/completion_tb.sv` (3029 verificações):

- **T1 a T18, dirigidos:** cada caso compara com vetores escritos à mão
  (quais barramentos e quais portas do ROB ligam) e confere os campos
  repassados. Cobrem ALU, `jalr` e desvio condicional, store, load (inclusive
  para `x0`), exceções de load e de store, dado do load, tag 0, as quatro
  fontes no mesmo ciclo, entradas inválidas com lixo e com `X`, flush, reuso
  de tag depois do flush, valores-limite e a disputa da porta 2 (load mais
  antigo, store mais antigo através da volta do `age`, load sem exceção que
  não disputa).
- **R, aleatório:** 3000 ciclos com flush aleatório, contra as regras.