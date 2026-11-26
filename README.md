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
| `make test T=core` | Roda só um testbench |
| `make test T="decode fetch"` | Roda uma lista de testbenches |
| `make core` | Atalho: o nome do teste também é um alvo |
| `make test T=core IVFLAGS=-DTRACE` | Roda com o traço de execução ligado (veja abaixo) |
| `make lint` | Verifica todo o RTL com o Verilator |
| `make clean` | Apaga a pasta `build/` com os simuladores gerados |

Um teste que passa imprime `PASS`. Se algum falhar, o `make` para, imprime
`<teste> (<parâmetros>) FAIL` e termina com código de saída diferente de zero.

### Vendo a execução

`IVFLAGS` passa flags extras ao `iverilog`. Com `-DTRACE`, o
`tb/integration/core_tb.sv` imprime duas coisas:

```sh
make test T=core IVFLAGS=-DTRACE
```

- **Uma linha por ciclo**, com o estado de cada estágio: PC buscado, ocupação
  da FIFO, `valid`/`ready` do Decode, se o Dispatch aceitou o bundle e que
  slots alocaram no ROB, tags livres no rename, entradas livres nas duas RS,
  emissões para a ALU e para a AGU, os write-backs, os commits e o flush.
- **Uma linha `RET` por retirada**, em ordem de programa: índice, ciclo, lane,
  PC (do modelo de referência), `x<rd> <- valor`, a tag física usada e a tag
  devolvida à free list; mais linhas para store, load e flush.

```
   3  pc=0000000000001024 fifo=1 dec=1/1 disp=1 alloc=111 ren=32 rs=8/4
   4  pc=0000000000001030 fifo=1 dec=1/1 disp=1 alloc=111 ren=29 rs=5/4  ALU<-t32
   5  pc=000000000000103c fifo=1 dec=1/1 disp=1 alloc=111 ren=27 rs=3/4  WB0=t32<-0000000000000005
   6  pc=0000000000001048 fifo=1 dec=1/1 disp=1 alloc=111 ren=24 rs=0/4  ALU<-t37  C=x1/t32
RET   0  cyc=   6 lane=0  pc=0000000000001000  x1 <- 0000000000000005   tag=t32 livre=t1
```

Cada conjunto de parâmetros do teste imprime o seu próprio traço, um depois
do outro (o `core` roda com `DEEP2 = 0` e `DEEP2 = 1`). Para ver só um:
`make core IVFLAGS=-DTRACE` continua rodando os dois; filtre a saída ou
comente o `PARAMS_core` no Makefile.

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

`make pnr` roda o LibreLane 3.0.17 dentro da imagem oficial
(`Dockerfile.pnr`). A máquina precisa só de docker e de um PDK baixado pelo
Ciel em `~/.ciel` (outro caminho: `make pnr PDK_ROOT=/caminho`).

Sem argumentos, `make pnr` roda o exemplo `spm` do LibreLane em
`build/spm`, só para conferir que o flow e o PDK funcionam. O topo
`rtl/core` ainda não tem config: a Branch Unit e o Memory não existem e
aparecem nele como portas. Para rodar o flow de um bloco, passe a config dele, com caminho a
partir da raiz do repositório:

```sh
make pnr                                     # exemplo spm
make pnr PNR_CONFIG=rtl/rename/config.json   # bloco de rename
```

Os resultados ficam em `runs/`, ao lado da config.
