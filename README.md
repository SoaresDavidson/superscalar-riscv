# Superscalar RISC-V

Núcleo RV32IM superescalar dinâmico (fora de ordem) em SystemVerilog, baseado
em Shen & Lipasti, *Modern Processor Design*. A especificação de cada etapa
fica na [wiki](superscalar-riscv.wiki/Home.md) e as decisões de projeto em
[Decisoes-de-Projeto](superscalar-riscv.wiki/Decisoes-de-Projeto.md).

## Estrutura

| Pasta | Conteúdo |
| --- | --- |
| `rtl/<bloco>/` | RTL sintetizável, uma pasta por bloco do pipeline |
| `tb/unit/` | Testbenches auto-verificáveis, um por módulo |
| `tb/integration/` | Testbenches de vários módulos ligados (até o core inteiro) |
| `docs/desenho_caminho_dados/` | Diagramas do caminho de dados (draw.io) |
| `superscalar-riscv.wiki/` | Wiki do projeto (repositório git separado) |

## Requisitos

- [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`)
- GNU Make
- [Verilator](https://www.veripool.org/verilator/), apenas para `make lint`

## Compilando e testando com o Makefile

Todos os comandos são executados na raiz do repositório. Para aprender a
ferramenta em si, veja o tutorial [Make](superscalar-riscv.wiki/Makefile.md)
na wiki.

| Comando | O que faz |
| --- | --- |
| `make test` | Roda **todos** os testbenches (unitários e de integração) |
| `make test-unit` | Roda só os de `tb/unit/` |
| `make test-integration` | Roda só os de `tb/integration/` |
| `make test T=register_rename` | Roda só um testbench |
| `make test T="register_rename rob"` | Roda uma lista de testbenches |
| `make register_rename` | Atalho: o nome do teste também é um alvo |
| `make lint` | Verifica todo o RTL com o Verilator |
| `make clean` | Apaga a pasta `build/` com os simuladores gerados |

Um teste que passa imprime `PASS`. Se algum falhar, o `make` para, imprime
`<teste> (<parâmetros>) FAIL` e termina com código de saída diferente de zero.

### Adicionando um teste

O Makefile descobre os testes pelos nomes dos arquivos, sem lista manual:

- todo arquivo `.sv` dentro de `rtl/` entra na compilação;
- cada `tb/unit/<nome>_tb.sv` ou `tb/integration/<nome>_tb.sv` vira um teste
  chamado `<nome>`; o nome não pode se repetir entre as duas pastas;
- o módulo de topo do testbench precisa se chamar `<nome>_tb`;
- o testbench imprime `PASS` no final e chama `$fatal` quando uma verificação
  falha.

Exemplo: criar `tb/unit/rob_tb.sv` com `module rob_tb;` já faz
`make test T=rob` funcionar.

### Docker

Para não instalar as ferramentas na máquina, use a imagem do `Dockerfile`, que
traz Icarus Verilog, Verilator e make. Construa uma vez:

```sh
docker build -t superscalar-riscv .
```

e rode os alvos do Makefile com o repositório montado em `/work`:

```sh
docker run --rm -v "$PWD":/work superscalar-riscv            # make test
docker run --rm -v "$PWD":/work superscalar-riscv make lint
docker run --rm -it -v "$PWD":/work superscalar-riscv bash   # shell no container
```

### Síntese física (LibreLane)

`make librelane` roda o LibreLane 3.0.17 dentro da imagem oficial
(`Dockerfile.librelane`). A máquina precisa só de docker e de um PDK baixado pelo
Ciel em `~/.ciel` (outro caminho: `make librelane PDK_ROOT=/caminho`).

Sem argumentos, `make librelane` roda o exemplo `spm` do LibreLane em
`build/spm`, só para conferir que o flow e o PDK funcionam. O topo
`rtl/core` ainda não tem config: a Branch Unit e o Memory não existem e
aparecem nele como portas. Para rodar o flow de um bloco, passe a config dele, com caminho a
partir da raiz do repositório:

```sh
make librelane                                     # exemplo spm
make librelane LIBRELANE_CONFIG=rtl/rename/config.json   # bloco de rename
make librelane-all -j4                             # todas as configs rtl/*/config*.json
make -s librelane-status                           # progresso da última rodada de cada config
```

Os resultados ficam em `runs/`, ao lado da config.
