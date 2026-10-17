# Superscalar RISC-V

Dynamic (out-of-order) superscalar RV64IM core in SystemVerilog, built from
Shen & Lipasti, *Modern Processor Design: Fundamentals of Superscalar
Processors*. The book is the conceptual reference; the wiki is the spec.

## Sources of truth, in order

1. `../superscalar-riscv.wiki/Decisoes-de-Projeto.md` — decided and open design
   choices. Do not decide an item marked "em aberto"; stop and ask.
2. `../superscalar-riscv.wiki/<Stage>.md` — behavior of each stage (Fetch, Decode,
   Register-Rename, Dispatch, Issue, Execute, Memory, Completion, Retirement,
   Branch-Prediction, Pipeline-Control).
3. `rtl/<block>/README.md` — the interface contract of an implemented block.
4. Book chapters: 4 (superscalar organization), 5.1 (instruction flow, branch
   prediction), 5.2 (register data flow: rename, reservation stations, ROB),
   5.3 (memory data flow: load/store queues, disambiguation).

When code and wiki disagree, report it instead of silently picking one.

## Fixed parameters

- ISA: RV64IM without C and without division (see decision 1). 57
  instructions: the 52 of RV64I plus `MUL`, `MULH`, `MULHSU`, `MULHU`, `MULW`.
- `XLEN` = 64: registers and addresses are 64 bits wide.
- Instruction width: 32 bits, fixed, 4-byte aligned — the C extension is out,
  so the slots of a fetch bundle sit at elaboration-time offsets and decode
  in parallel.
- Width: 3 instructions per cycle for fetch, decode, dispatch and retire.
  Width is a module parameter, never a hard-coded 3.
- Data bus: 64 bits.
- Instruction bus: at least 96 bits; **96 or 128 is still undecided**. Express
  it as instructions per fetch (`IFETCH_WIDTH`) and derive the bit width, so
  the ratio to `WIDTH` stays legible.
- Register rename: three variants exist in `rtl/rename/` (RRF, ROB-based,
  unified PRF). **Which one the core uses is still undecided** — keep new
  blocks independent of the variant (talk only in tags) until it is chosen.

## Layout

- `rtl/<block>/` — synthesizable RTL, one directory per pipeline block.
- `tb/unit/<name>_tb.sv` — self-checking unit testbench for module `<name>`.
- `tb/integration/<name>_tb.sv` — self-checking testbench of several blocks
  wired together. Test names are unique across both folders.
- `docs/desenho_caminho_dados/` — draw.io datapath diagrams.
- `../superscalar-riscv.wiki/` — separate git repository (the GitHub wiki),
  cloned as a sibling of this repo, outside it.
- `docsDecode/` — drafts of wiki pages for the Decode stage, to be moved into
  the wiki repo later. Git-ignored here.

## Commands

- `make test` — every testbench; `make test-unit` / `make test-integration` —
  one suite; `make test T=register_rename` — one test.
- `make lint` — Verilator lint over all RTL (requires `verilator`).
- A test with several parameter sets lists them in `PARAMS_<name>` in the
  Makefile.

## RTL conventions

- SystemVerilog, `-g2012` subset that Icarus accepts. `always_ff` for state,
`always_comb` for logic, `logic` everywhere; no latches.
- Synchronous active-high `reset`; `flush` cancels speculative state.
- Handshakes are `valid`/`ready`; a transfer happens when both are high.
- `x0` never allocates a tag and always reads 0.
- Identifiers and code comments in English; docs and wiki in Portuguese.

### Icarus 12.0 limits (measured, not guessed)

These shape how per-slot logic is written. The first two are hard errors, the
last two compile and silently misbehave — which is worse.

- **No variable index followed by a second select.** `a[i][0]` with `int i`
  inside `always_*` aborts the elaborator. Index per-slot vectors with a
  `genvar` in a `generate` loop, never with a loop variable.
- **No `'{field: value}` assignment patterns.** Syntax error. Assign struct
  fields one by one.
- **`break` is accepted, warned about with `sorry:`, and then ignored.** Never
  use it. For "closest previous writer", loop upward with no break and let the
  last write win.
- **`always_comb` with genvar-indexed targets** elaborates with
  `has no sensitivities`. Use continuous `assign` inside the `generate` block.
- **No `return` in a task.** Hard error. Guard with
  `if (cond) begin ... end else begin ... end` instead of an early exit.
- **Never read a slot as `arr[i].field`. Copy the element to a scalar
  temporary first:** `s = arr[i]; ... s.field`. With `WIDTH = 1` -- a packed
  array of ONE struct -- `arr[0].field` reads `x` while the storage itself is
  correct, so the bug appears only in the narrowest parameter set and looks
  like a decode bug. Writing works the same way: build the struct in a scalar
  temporary and assign the element once (`arr[i] = s`), never field by field.
- **No `inside` operator.** `sorry: not supported`, and `iverilog` then exits
  non-zero leaving the PREVIOUS `.vvp` in place: run a stale binary and the
  same failure repeats while the source already says otherwise. Always check
  the exit status, never just grep the output.

Width casts, not bit-selects: `PB'(k)` — `k[PB-1:0]` trips the same index
limit, and implicit truncation (`p = k`) fails `make lint` with Verilator
`WIDTHTRUNC`.

## Toolchain note

There is no `-march` string for "M without division". With `-march=rv64im`
gcc assumes `DIV`/`REM` exist and will emit them for any `/` or `%`. Test
programs must avoid division, and the test flow should scan the binary for
those opcodes before running.

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
- Final verification: **decision 13 needs redefinition and is on hold.** Its
  original plan — the same binaries run on the scalar RV32I pipeline and on
  this core, with matching final architectural state — is invalid now that
  `XLEN` is 64, because RV32I and RV64IM binaries are not interchangeable. Do
  not rely on decision 13 until the group picks a new reference.