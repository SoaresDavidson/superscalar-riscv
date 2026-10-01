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

use docker para não precisar instalar as dependências. O Makefile detecta se está rodando dentro de um container e ajusta os caminhos de montagem. Para rodar o Makefile dentro do container, rode:

```sh
docker build -t superscalar-riscv .
```

depois disso, rode o container com o diretório atual montado em `/workdir`:

```sh
docker run --rm -it -v $(pwd):/workdir superscalar-riscv
```

esse comando abre um shell dentro do container, com o diretório atual montado em `/workdir`. A partir daí, você pode rodar os comandos do Makefile normalmente, como `make test` ou `make lint`.
exemplo de uso:

```sh
docker run --rm -it -v $(pwd):/workdir superscalar-riscv make test #roda todos os testes
docker run --rm -it -v $(pwd):/workdir superscalar-riscv make lint #roda o verificador de lint
```
