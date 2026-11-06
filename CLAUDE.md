# Superscalar RISC-V

Dynamic (out-of-order) superscalar RV64I core in SystemVerilog, built from
Shen & Lipasti, *Modern Processor Design: Fundamentals of Superscalar
Processors*. The book is the conceptual reference; the wiki is the spec.

## Sources of truth, in order

1. `superscalar-riscv.wiki/Decisoes-de-Projeto.md` — decided and open design
   choices. Do not decide an item marked "em aberto"; stop and ask.
2. `superscalar-riscv.wiki/<Stage>.md` — behavior of each stage (Fetch, Decode,
   Register-Rename, Dispatch, Issue, Execute, Memory, Completion, Retirement,
   Branch-Prediction, Pipeline-Control).
3. `rtl/<block>/README.md` — the interface contract of an implemented block.
4. Book chapters: 4 (superscalar organization), 5.1 (instruction flow, branch
   prediction), 5.2 (register data flow: rename, reservation stations, ROB),
   5.3 (memory data flow: load/store queues, disambiguation).

When code and wiki disagree, report it instead of silently picking one.

## Fixed parameters

- ISA: RV64I, no multiplier, no divider, no C extension (decided at the
  alignment meeting; wiki decisions 1 and 11). Instruction table and RV64
  encodings in `superscalar-riscv.wiki/ISA-RV64.md`. Instructions are 32 bits,
  the six formats are the same as RV32, with 32 registers (5-bit specifiers).
- Data width vs instruction width are independent: the DATA is 64 bits, the
  INSTRUCTION is 32 bits. `XLEN = 64` is a module parameter, never a hard-coded
  64 or 32. Registers, PC, immediates (sign-extended to `XLEN`), ALU, AGU and
  branch compare all use `XLEN`. RV64 adds the `W` instructions (`ADDW`,
  `SLLIW`, ...: operate on the low 32 bits, sign-extend the result), `LD`/`SD`/
  `LWU`, and 6-bit `shamt`. There is no MUL/DIV functional unit.
- Width: 3 instructions per cycle for fetch, decode, dispatch and retire.
  Width is a module parameter, never a hard-coded 3.
- Register rename: the core uses the **unified PRF** variant in `rtl/rename/`
  (wiki decision 14). New blocks still talk to rename only in tags, never in
  physical-register indices, so the rest of the pipeline stays variant-agnostic.

- Decode <-> Execute interface: the micro-operation types the Decode
  produces and the Execute consumes live in a single package,
  `rtl/execute/execute_pkg.sv`. Do not create a second package for the
  same information. Changing those types is a contract change between the
  two stages: agree it with both owners and update the wiki Execute page
  and the block READMEs in the same commit.

## Layout

- `rtl/<block>/` — synthesizable RTL, one directory per pipeline block.
- `tb/unit/<name>_tb.sv` — self-checking unit testbench for module `<name>`.
- `tb/integration/<name>_tb.sv` — self-checking testbench of several blocks
  wired together. Test names are unique across both folders.
- `docs/desenho_caminho_dados/` — draw.io datapath diagrams.
- `superscalar-riscv.wiki/` — separate git repository (the GitHub wiki).

## Commands

- `make test` — every testbench; `make test-unit` / `make test-integration` —
  one suite; `make test T=RRF` — one test.
- `make lint` — Verilator lint over all RTL (requires `verilator`).
- A test with several parameter sets lists them in `PARAMS_<name>` in the
  Makefile.

## RTL conventions

- SystemVerilog, `-g2012` subset that Icarus accepts. `always_ff` for state,
  `always_comb` for logic, `logic` everywhere; no latches.
- Synchronous active-high `reset`; `flush` cancels speculative state.
- Handshakes are `valid`/`ready`; a transfer happens when both are high.
- `x0` never allocates a tag and always reads 0.
- Identifiers in English; code comments, docs and wiki in Portuguese.

## Workflow

- Specify before building: the stage's wiki page must describe the interface
  and behavior before the RTL is written.
- Write the testbench first. It must print `PASS` at the end and call `$fatal`
  on any failed check; never rely on inspecting waveforms.
- A block is done only when `make test` passes. Report failures with output.
- Cover the out-of-order hazards explicitly: same register as source and
  destination, dependencies inside one bundle, full structures (back-pressure),
  flush while results are in flight, and tag reuse after flush.
- Changing a module interface means updating its README and wiki page in the
  same change.
- Final verification (decision 13, reopened): the RV32I scalar pipeline can no
  longer be the reference, since this core is RV64I. A dedicated RV64I reference
  model (an ISA simulator such as Spike, or equivalent) is needed and is not
  decided yet.
