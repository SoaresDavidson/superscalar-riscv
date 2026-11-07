# `decode` — interface contract

Behavior is specified in `docsDecode/Decode.md` (destined for the wiki as the
`Decode` page). This file is only the contract of the implemented block: what
the ports mean and what a consumer may assume. When the two disagree, the spec
wins and this file is stale — report it.

**Status: implemented.** `make test T=decode` passes at `WIDTH` 1, 2, 3 and 4;
`make lint` is clean.

## Parameters

| Parameter | Default | Note |
|---|---|---|
| `WIDTH` | 3 | instructions per cycle (decision 2). Never a literal in the RTL. |

`WIDTH` is the only parameter. `XLEN` is **not** one: it comes from
`execute_pkg::XLEN`, the same way `alu.sv` and `agu.sv` take it. The reason is
concrete — `uop_t.pc` and `uop_t.imm` are `xlen_t`, fixed at the *package*
width, so an overridable module `XLEN` would leave the ports one width and the
struct another with no error anywhere. It also tripped Verilator's `VARHIDDEN`,
by shadowing the package name.

## Ports

### Clock and control

| Port | Dir | Meaning |
|---|---|---|
| `clk` | in | — |
| `reset` | in | synchronous, active high. Clears pipeline state; `out_valid` goes to 0. |
| `flush` | in | same effect on in-flight content, without clearing configuration. **Takes precedence over the handshake**: a bundle is not propagated even if `in_valid && in_ready` were high that cycle. |

### Fetch -> Decode

| Port | Dir | Meaning |
|---|---|---|
| `in_valid` | in | a bundle is being offered |
| `in_ready` | out | the stage can accept one. Transfer happens when both are high. Falls while a bundle is parked at the output and the consumer is not taking it. |
| `in_slot_valid` | in | `[WIDTH-1:0]`. May be partially valid, zeros to the right: Fetch brought fewer than `WIDTH` instructions. Invalid slots produce `uop.valid = 0` and take no part in dependency computation. |
| `in_inst` | in | `[WIDTH-1:0][31:0]`, slot 0 first in program order |
| `in_pc` | in | `[WIDTH-1:0][XLEN-1:0]` |

### Decode -> Register Rename / Dispatch

| Port | Dir | Meaning |
|---|---|---|
| `out_valid` | out | the bundle is available |
| `out_ready` | in | the consumer accepts it. **All or nothing** (decision 15): the whole bundle is accepted or none of it. There is no partial-prefix acceptance, because the dependencies below were computed for the bundle as a whole. |
| `out_uop` | out | `uop_t [WIDTH-1:0]` from `execute_pkg`. Architectural registers only — no tag, no PRF index, no ROB index — so any rename variant consumes it unchanged. |

One `op` field of type `exec_op_t` carries what used to need six: the FU comes
from `fu_of(op)`, the access size and signedness are in the `AGU_*` op, and the
32-bit `W` semantics are in the `ALU_*W` op. That makes `uop_t` nearly
field-for-field identical to `fu_req_t`, so Dispatch copies fields instead of
translating enums. Spec section 5 has the full mapping.

### Intra-bundle dependencies (decision 3)

Three masks, `[WIDTH-1:0][WIDTH-1:0]` each, **one-hot per slot**. Bit `j` of
slot `i`'s mask (always `j < i`) marks the **closest** earlier writer of that
register inside this same bundle; all-zero means none, and the rename reads its
Mapping Table instead.

| Port | Dir | Meaning |
|---|---|---|
| `out_dep_rs1` | out | producer of slot `i`'s source 1 |
| `out_dep_rs2` | out | producer of slot `i`'s source 2 |
| `out_dep_rd` | out | producer of slot `i`'s **destination** — the WAW case |

A producer must satisfy all of: `j < i` strictly, `uop[j].valid`,
`uop[j].has_dest`, `uop[j].rd != 0`. The Rename never compares register
numbers — that is the point of decision 3.

`out_dep_rd` is what `PRFRename` derives `old_tag` from, and it is not
optional. Without it, two writers of the same register in one bundle both
report the pre-bundle tag as `old_tag`; the ROB then returns the same
`commit_old_tag` twice, so that tag enters the free list twice while the
intermediate one leaks. Two extra rules apply to it:

- it is all-zero for a slot that allocates nothing (store, branch, `rd = x0`,
  illegal encoding) — with no allocation there is no `old_tag` to chain;
- a non-allocating slot does not break the chain: with a store between two
  writers of `x5`, the second writer points at the first, not at the store.

This is the format `PRFRename` consumes directly. The earlier version of this
contract exported `*_in_bundle` (one bit) plus `*_producer` (a binary index)
and had no `rd` mask at all, which would have forced Dispatch to convert in
the middle and still left the WAW bug.

### JAL redirect (decision 7, spec section 10)

| Port | Dir | Meaning |
|---|---|---|
| `redirect_valid` | out | one-cycle pulse, exactly one per accepted bundle, even with two `JAL`s in it. Pulses once whatever happens downstream, because Fetch must be steered once. |
| `redirect_pc` | out | `pc` of the redirecting slot + `imm_j`. Held stable with the bundle. |
| `out_slot_kill` | out | `[WIDTH-1:0]`. Slots to the **right** of the redirecting one are on the wrong path. They reach the Rename with `uop.valid = 0` rather than the bundle being re-presented (decision 15), and they appear in none of the three dependency masks. |

The **first** `JAL` in the bundle wins: every slot after it is already on the
wrong path.

Conditional branches do **not** redirect here: section 10.2 of the spec (the
general branch correction) is still an open decision.

## Consumer-visible conventions

- **`x0`:** `rd == x0` lowers `has_dest`; `rs1`/`rs2 == x0` lowers
  `rs1_valid`/`rs2_valid` (spec section 9.4). Therefore: **an invalid source
  means the operand is 0**, and the `rs1`/`rs2` field must not be read when
  its `*_valid` is low.
- **Illegal encodings** keep flowing: `illegal = 1`, `op = OP_NONE`, nothing
  allocated. Decode never aborts or stalls; Retirement raises the exception
  (spec section 9.5). The whole M extension is illegal here — `MUL` as much as
  `DIV` (decisions 1 and 11).
- **System instructions** (`FENCE`, `FENCE.I`, `ECALL`, `EBREAK`, CSR) also
  come out with `op = OP_NONE`, but with `illegal = 0`. The `illegal` bit is
  what tells the two apart.
- **`serializing`** is set here (by opcode and `funct3`) and consumed by
  Pipeline-Control. `FENCE` sets it as the conservative reading while
  decision 9 is open: draining is never wrong, treating a fence as a nop is
  only right if the group decides so.

## Icarus 12.0 note measured while writing this block

Add to the list in `AGENTS.md`: **a constant select read inside an `always_*`
block** — a genvar index like `uses_rs1[i]`, a part-select like `inst[31:20]`,
or a struct field read back like `!u.illegal` — makes Icarus print
`sorry: constant selects in always_* processes are not currently supported
(all bits will be included)` and widen the sensitivity list to the whole
vector. Behavior stays correct, unlike the other `sorry:` cases, but every
such read is hoisted into a continuous `assign` here so a real `sorry:` is not
lost in the noise. A **variable** select inside `always_*` is fine.
