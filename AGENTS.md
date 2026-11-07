# Superscalar RISC-V

Dynamic (out-of-order) superscalar RV64I core in SystemVerilog, built from
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

- ISA: RV64I, no multiplier, no divider, no C extension (decided at the
  alignment meeting; wiki decisions 1 and 11). Instruction table and RV64
  encodings in `../superscalar-riscv.wiki/ISA-RV64.md`. Instructions are 32 bits,
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
  `rtl/execute/execute_pkg.sv`. That is where `uop_t` lives; there is no
  `rtl/core_pkg.sv` any more. Do not create a second package for the
  same information — two packages both declared `ALU_ADD`, `ALU_SUB`,
  `ALU_SLL`... and Dispatch, which needs both at once, collided. Changing
  those types is a contract change between the two stages: agree it with both
  owners and update the wiki Execute page and the block READMEs in the same
  commit.
- Three widths with similar names, never interchangeable: `REG_W` = 5 is an
  ARCHITECTURAL register `x0`-`x31`; `TAG_W` = `$clog2(PRF_ENTRIES)` is a
  PHYSICAL register, which is what the FUs and the CDB carry; `AGE_W` is a
  position in program order. A destination field on a functional unit is a
  tag, never an architectural number.

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
  one suite; `make test T=decode` — one test.
- `make lint` — Verilator lint over all RTL (requires `verilator`).
- A test with several parameter sets lists them in `PARAMS_<name>` in the
  Makefile.
- The editor lints too, through `.vscode/settings.json`, and it lints **one
  file at a time** — so that file prepends the package explicitly:
  `verilog.linting.verilator.arguments` ends with
  `rtl/execute/execute_pkg.sv`. **Renaming or moving the package means
  editing that line in the same change**, or every file that imports it
  reports `Package/class 'execute_pkg' not found` followed by a cascade of
  bogus `syntax error, unexpected output` / `unexpected assign` — the port
  types are unknown, so the parser derails. `make lint` keeps passing the
  whole time, because the Makefile passes the package first. After editing
  that setting, reload the VS Code window: the extension reads it at load and
  re-lints a file on save.
- `make lint` covers RTL only, never `tb/`. The editor does lint testbenches
  with `-Wall`, so warnings can show up there that `make lint` never reports.

## RTL conventions

- SystemVerilog, `-g2012` subset that Icarus accepts. `always_ff` for state,
  `always_comb` for logic, `logic` everywhere; no latches.
- Synchronous active-high `reset`; `flush` cancels speculative state.
- Handshakes are `valid`/`ready`; a transfer happens when both are high.
- `x0` never allocates a tag and always reads 0.
- Identifiers and code comments in English; docs and wiki in Portuguese.

### Icarus 12.0 limits (measured, not guessed)

These shape how per-slot logic is written. The first two are hard errors, the
rest compile and silently misbehave — which is worse.

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
- **No constant select read inside an `always_*` block.** A genvar index
  (`uses_rs1[i]`), a part-select (`inst[31:20]`) or a struct field read back
  mid-block (`!u.illegal`) all produce
  `sorry: constant selects in always_* processes are not currently supported
  (all bits will be included)`, and the sensitivity list widens to the whole
  vector. Unlike the other `sorry:` cases the behavior stays correct, but
  hoist every such read into a continuous `assign` anyway: a `sorry:` left in
  the build is noise that hides the next one. A **variable** select inside
  `always_*` is fine.
- **No `return` in a task.** Hard error. Guard with
  `if (cond) begin ... end else begin ... end` instead of an early exit.
- **Never read a slot as `arr[i].field`. Copy the element to a scalar
  temporary first:** `s = arr[i]; ... s.field`. With `WIDTH = 1` -- a packed
  array of ONE struct -- `arr[0].field` reads `x` while the storage itself is
  correct, so the bug appears only in the narrowest parameter set and looks
  like a decode bug. Writing works the same way: build the struct in a scalar
  temporary and assign the element once (`arr[i] = s`), never field by field.
  Unpacked per-slot arrays dodge the whole family of index limits and are
  preferred for internal signals.
- **No `inside` operator.** `sorry: not supported`, and `iverilog` then exits
  non-zero leaving the PREVIOUS `.vvp` in place: run a stale binary and the
  same failure repeats while the source already says otherwise. Always check
  the exit status, never just grep the output.

Width casts, not bit-selects: `PB'(k)` — `k[PB-1:0]` trips the same index
limit, and implicit truncation (`p = k`) fails `make lint` with Verilator
`WIDTHTRUNC`.

## Toolchain note

The core has **no multiplier and no divider** (decisions 1 and 11), so
`-march=rv64i` is the string to build test programs with. With `rv64im` gcc
assumes `MUL`/`DIV`/`REM` exist and emits them for any `*`, `/` or `%`; the
Decode marks every `funct7 = 0000001` encoding illegal, so such a binary traps
instead of running. Test programs must avoid multiplication and division, and
the test flow should scan the binary for those opcodes before running.

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
  decided yet. Do not rely on decision 13 until the group picks a reference.
