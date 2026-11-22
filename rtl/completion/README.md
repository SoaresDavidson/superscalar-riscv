# `completion` — contrato de interface

Recebe as respostas das quatro fontes de resultado (ALU, Branch Unit, AGU e
dado do load vindo do Memory) e, no mesmo ciclo, liga os 3 barramentos de
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
| `ROB_N` | 4 | portas de resposta: quem **termina instrução** (ALU, Branch Unit, AGU, load). É o `WB_N = 4` que o `retire_team` exige |

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
| `agu_resp_valid`, `agu_resp` | entrada | `resp_valid`, `resp` da `agu` | resposta da AGU |
| `agu_resp_ready` | saída | `resp_ready` da `agu` | sempre 1 |
| `agu_is_load` | entrada | **origem em aberto** (Pendências) | a resposta da AGU é de um load; vale com `agu_resp_valid` |
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
| AGU | — (o resultado é um endereço) | 2, só stores e exceções |
| Load (Memory) | 2 | 3 |

Regras:

```
wb_valid[p]       = src_valid && !flush && wr_en && dst_tag != 0 && !exception
rob_resp_valid[0] = !flush && alu_resp_valid
rob_resp_valid[1] = !flush && br_resp_valid
rob_resp_valid[2] = !flush && agu_resp_valid && (!agu_is_load || exception)
rob_resp_valid[3] = !flush && lsu_resp_valid
*_resp_ready      = 1
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
- Nenhuma fonte é segurada: todos os `*_resp_ready` ficam em 1, também no
  ciclo do flush (a resposta é consumida e descartada).

O que fica com as fontes: não entregar, depois do flush, a resposta de uma
instrução descartada (a tag pode já ter sido realocada). A ALU e a AGU já
fazem isso com `flush_age`.

## Pendências

Ver `docs/completion/Completion.md`, "Pontos em aberto". As que mudam esta
interface ou a ligação:

- **`agu_is_load`** (item 3) não tem origem no `core`. A proposta é a `agu`
  exportar o sinal, que ela já calcula por dentro. O `backend_tb` o obtém de
  uma tabela indexada pelo `age`, que só existe no testbench.
- **Porta do Memory** (item 6): `lsu_*` supõe a mesma `fu_resp_t`, como no
  modelo do `backend_tb`. O Memory não tem especificação.
- **Regra de write-back** (item 8): a do `rtl/issue/README.md` é
  `resp_valid && wr_en`; a desta interface também bloqueia tag 0, exceção e
  flush. O resultado é o mesmo em toda execução correta.

## Teste

`tb/unit/completion_tb.sv` (3024 verificações):

- **T1 a T15, dirigidos:** cada caso compara com vetores escritos à mão
  (quais barramentos e quais portas do ROB ligam) e confere os campos
  repassados. Cobrem ALU, `jalr` e desvio condicional, store, load (inclusive
  para `x0`), exceções de load e de store, dado do load, tag 0, as quatro
  fontes no mesmo ciclo, entradas inválidas com lixo e com `X`, flush, reuso
  de tag depois do flush e valores-limite.
- **R, aleatório:** 3000 ciclos com flush aleatório, contra as regras.