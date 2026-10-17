# `decode` — interface contract

Behavior is specified in `docsDecode/Decode.md` (destined for the wiki as the
`Decode` page). This file is only the contract of the implemented block: what
the ports mean and what a consumer may assume. When the two disagree, the spec
wins and this file is stale — report it.

**Status: stub.** `decode.sv` has the final port list and no behavior yet;
`tb/unit/decode_tb.sv` fails on purpose until the logic is written.

## Parameters

| Parameter | Default | Note |
|---|---|---|
| `WIDTH` | 3 | instructions per cycle (decision 2). Never a literal in the RTL. |
| `XLEN` | `core_pkg::XLEN` = 64 | register and address width (decision 1). |
| `PROD_BITS` | derived | `max($clog2(WIDTH), 1)`. **Do not override.** The `max(..., 1)` keeps `WIDTH = 1` legal, where `$clog2(1) = 0` would give a zero-width field. |

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
| `in_ready` | out | the stage can accept one. Transfer happens when both are high. |
| `in_slot_valid` | in | `[WIDTH-1:0]`. May be partially valid, zeros to the right: Fetch brought fewer than `WIDTH` instructions. Invalid slots produce `uop.valid = 0` and take no part in dependency computation. |
| `in_inst` | in | `[WIDTH-1:0][31:0]`, slot 0 first in program order |
| `in_pc` | in | `[WIDTH-1:0][XLEN-1:0]` |

### Decode -> Register Rename / Dispatch

| Port | Dir | Meaning |
|---|---|---|
| `out_valid` | out | the bundle is available |
| `out_ready` | in | the consumer accepts it. **All or nothing** (decision 15): the whole bundle is accepted or none of it. There is no partial-prefix acceptance, because the dependencies below were computed for the bundle as a whole. |
| `out_uop` | out | `core_pkg::uop_t [WIDTH-1:0]`. Architectural registers only — no tag, no PRF index, no ROB index — so any rename variant consumes it unchanged. |

### Intra-bundle dependencies (decision 3)

`bundle_dep_t` of spec section 8, flattened: the type depends on `WIDTH`, and a
SystemVerilog package is not parameterizable, so it cannot live in
`core_pkg.sv` next to `uop_t`.

| Port | Dir | Meaning |
|---|---|---|
| `out_dep_rs1_in_bundle` | out | `[WIDTH-1:0]`. Bit `i`: source 1 of slot `i` has a producer earlier in this same bundle. |
| `out_dep_rs2_in_bundle` | out | same, for source 2 |
| `out_dep_rs1_producer` | out | `[WIDTH-1:0][PROD_BITS-1:0]`. Which slot is the **closest** writer: the largest `j < i` that matches. Meaningless when the matching `*_in_bundle` bit is 0. |
| `out_dep_rs2_producer` | out | same, for source 2 |

A producer must satisfy all of: `j < i` strictly, `uop[j].valid`,
`uop[j].has_dest`, `uop[j].rd != 0`. The Rename never compares register
numbers — that is the point of decision 3.

### JAL redirect (decision 7, spec section 10)

| Port | Dir | Meaning |
|---|---|---|
| `redirect_valid` | out | one-cycle pulse. Exactly one per bundle, even with two `JAL`s in it. |
| `redirect_pc` | out | `pc` of the redirecting slot + `imm_j` |
| `out_slot_kill` | out | `[WIDTH-1:0]`. Slots to the **right** of the redirecting one are on the wrong path. They reach the Rename with `valid = 0` rather than the bundle being re-presented (decision 15). |

Conditional branches do **not** redirect here: section 10.2 of the spec (the
general branch correction) is still an open decision.

## Consumer-visible conventions

- **`x0`:** `rd == x0` lowers `has_dest`; `rs1`/`rs2 == x0` lowers
  `rs1_valid`/`rs2_valid` (spec section 9.4). Therefore: **an invalid source
  means the operand is 0**, and the `rs1`/`rs2` field must not be read when
  its `*_valid` is low.
- **Illegal encodings** keep flowing: `illegal = 1`, `uop_class = UC_ILLEGAL`,
  nothing allocated. Decode never aborts or stalls; Retirement raises the
  exception (spec section 9.5).
- **`serializing`** is set here (by opcode and `funct3`) and consumed by
  Pipeline-Control.
