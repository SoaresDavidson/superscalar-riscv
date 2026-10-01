# Simulation environment: Icarus Verilog for `make test`, Verilator for `make lint`.
# Usage:
#   docker build -t superscalar-riscv .
#   docker run --rm -v "$PWD":/work superscalar-riscv            # make test
#   docker run --rm -v "$PWD":/work superscalar-riscv make lint
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends iverilog verilator make findutils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY . .

CMD ["make", "test"]
