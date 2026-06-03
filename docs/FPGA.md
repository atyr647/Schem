# FPGA.md -- importing Yosys netlists into Schem's digital IR

Schem's cycle-accurate digital kernel (see `docs/DIGITAL.md`) runs a netlist of
**1-bit nets** and **primitive cells** (LUT / DFF / gate / MUX / MEM / ...).
This document specifies the **front door** that fills that netlist from real
hardware: the [Yosys](https://yosyshq.net) `write_json` netlist, which is the
universal entry point for "any RTL an open tool can read". The importer lives
in `src/digital/import_yosys.tcl` (namespace `::schem::digital::yosys`); the
tests in `tests/test_yosys_import.tcl` exercise it against the hand-authored
fixture `tests/fixtures/counter.yosys.json` so it runs with no Yosys installed.

```
RTL (Verilog/...)  --yosys synth+techmap-->  out.json  --import_yosys-->  digital IR  --> kernel
```

## 1. The Yosys JSON field reference

Produced by `write_json`. Top level:

```jsonc
{
  "creator": "Yosys <version> ...",          // provenance string
  "modules": { "<modName>": { ...module... }, ... },
  "models":  { ... }                          // only with `write_json -aig`
}
```

A **module**:

```jsonc
{
  "attributes": { "<name>": "<value>", ... }, // e.g. "top": "00..01" marks the top
  "parameter_default_values": { ... },
  "ports":    { "<portName>": <port>, ... },
  "cells":    { "<instName>": <cell>, ... },
  "memories": { "<memName>": <mem>,  ... },    // present when `memory` not fully mapped
  "netnames": { "<netName>": <net>,  ... }     // human names for debug; not load-bearing
}
```

A **port**:

```jsonc
{
  "direction": "input" | "output" | "inout",
  "bits": <bitvector>,        // LSB-first
  "offset": <int>,            // omitted when 0 (lowest declared bit index)
  "upto":   1,                // omitted when 0; 1 => declared MSB-first
  "signed": 1                 // omitted when 0
}
```

A **cell**:

```jsonc
{
  "hide_name": 0 | 1,                          // 1 => auto-generated name
  "type": "$_AND_" | "$dff" | "<submodule>" | ...,
  "parameters": { "<P>": "<binary-or-int>", ... },
  "attributes": { ... },
  "port_directions": { "<port>": "input"|"output"|"inout", ... }, // with -nopd: absent
  "connections": { "<port>": <bitvector>, ... } // LSB-first per port
}
```

A **netname**:

```jsonc
{ "hide_name": 0|1, "bits": <bitvector>, "offset": <int>, "upto": 1, "signed": 1 }
```

### Bit vectors -- the crux

A **bit vector** is a JSON array whose elements are *either*:

* an **integer** -- a unique id for one 1-bit net. The **same integer means the
  same physical net** wherever it appears (a port's `bits`, a driving cell's
  output `connections`, every consuming cell's input `connections`, and the
  `netnames` map). This is how connectivity is expressed: shared ids = wired
  together. Net ids are arbitrary positive integers and are **not** dense.
* a **constant string**: `"0"` (logic 0), `"1"` (logic 1), `"x"` (don't-care /
  undriven), `"z"` (high-impedance).

Bit vectors are **LSB-first**: element 0 is bit 0. Yosys's own worked example
(`write_json` docs) makes this explicit -- `.A({x, y})` where `x` is net 2 and
`y` is net 3 emits `"A": [ 3, 2 ]` (so `A[0] = y = 3`), and
`.C({4'd10, {4{x}}})` emits `"C": [ 2,2,2,2, "0","1","0","1" ]` -- the low four
bits are `x` (net 2), the high four are the constant `4'd10 = 1010` written
LSB-first as `0,1,0,1`.

Cell **parameters** are usually strings of binary digits (e.g. a 32-bit value
`"00000000000000000000000000101010"` = 42); width/polarity params like `WIDTH`,
`CLK_POLARITY`, `ARST_VALUE` are read this way (a bare decimal also appears for
some). The importer treats them as opaque until a mapping needs one.

## 2. Mapping Yosys cells to Schem primitives

`synth` lowers RTL to coarse word-level `$...` cells; an extra `techmap` (and
`abc`/`dfflibmap` in a real flow) lowers those to the single-bit **internal
gate library** `$_..._`. The importer targets the gate library first because
that set -- the `$_..._` gates plus `$_DFF_P_` plus `$mem_v2` -- is the minimal
"runs anything" vocabulary.

| Yosys cell | ports (LSB-first vectors) | Schem primitive | params translation | status |
|---|---|---|---|---|
| `$_NOT_` | A -> Y | `NOT` | -- | **done** |
| `$_AND_` `$_OR_` `$_XOR_` `$_NAND_` `$_NOR_` `$_XNOR_` `$_ANDNOT_` `$_ORNOT_` | A,B -> Y | `AND`/`OR`/`XOR`/... (name = type stripped of `$_`/`_`) | -- | **done** |
| `$_MUX_` | A,B,S -> Y; `Y = S?B:A` | `MUX` | -- | **done** |
| `$_DFF_P_` | C,D -> Q (rising edge) | `DFF` | `{clkpol 1 rstpol 0 rstval 0 async 0 enable 0}` | **done** |
| `$_DFF_N_` | C,D -> Q (falling) | `DFF` | `{clkpol 0 ...}` | TODO |
| `$_DFFE_[NP][NP]_` | C,D,EN -> Q | `DFF` | `{enable 1, clkpol/enpol from name}`, +EN | TODO |
| `$_SDFF_[NP][NP][01]_` | C,D,R -> Q (sync reset) | `DFF` | `{async 0 rstval 0/1 ...}`, +R | TODO |
| `$_DFF_[NP][NP][01]_` | C,D,R -> Q (async reset) | `DFF` | `{async 1 rstpol .. rstval ..}`, +R | TODO |
| `$_DLATCH_[NP]_` / `_[NP][NP][01]_` | E,D(,R) -> Q | `DLATCH` | level-sensitive | TODO |
| `$_AOI3_`/`$_OAI3_`/`$_AOI4_`/`$_OAI4_` | A,B,C(,D) -> Y | compound gate or `LUT` | `init` computed from the boolean fn | TODO |
| `$dff` | CLK,D -> Q (WIDTH-wide) | `DFF` x WIDTH | `WIDTH`, `CLK_POLARITY`; bit-blast D/Q | TODO |
| `$adff` | CLK,ARST,D -> Q | `DFF` x WIDTH async | `ARST_POLARITY`,`ARST_VALUE` | TODO |
| `$dffe` | CLK,EN,D -> Q | `DFF` x WIDTH +en | `EN_POLARITY` | TODO |
| `$sdff` | CLK,SRST,D -> Q | `DFF` x WIDTH sync | `SRST_POLARITY`,`SRST_VALUE` | TODO |
| `$mux` | A,B,S -> Y (WIDTH-wide) | `MUX` x WIDTH | `WIDTH` | TODO |
| `$and`/`$or`/`$xor`/`$not` | A,B -> Y (multi-bit) | gate x WIDTH | `A_WIDTH`/`B_WIDTH`/`Y_WIDTH` | TODO |
| `$add`/`$sub` | A,B -> Y | `ADD` | `A_WIDTH`/`B_WIDTH`/`Y_WIDTH`, signedness | TODO |
| `$eq`/`$ne`/`$lt`/`$gt`/`$ge`/`$le` | A,B -> Y | comparator | widths, signedness | TODO |
| `$mem_v2` / `$mem` | RD_*/WR_* port arrays | `MEM` | `{abits dbits words rdsync}` from `ABITS`/`WIDTH`/`SIZE`/`RD_CLK_ENABLE` | TODO |
| any other `$...` / submodule | -- | -- | **raise an error** (no silent drop) | by design |

Unmapped types hit the importer's `default` arm and raise a clear error telling
the user to run `techmap` (to reduce to the gate set) or to extend `MapCell`.
This guarantees nothing is silently dropped from a netlist.

### Multi-bit connections -> bit-blasted netId lists

Every cell port's bit vector is bit-blasted into a **list of 1-bit netIds**,
preserving LSB-first order, via `MapConn` -> `MapBit`. A word-level cell (e.g. a
WIDTH-8 `$dff`) is therefore represented with its `D`/`Q` already exploded into
8 nets; when those word cells are implemented they will be split into WIDTH
single-bit primitives sharing those nets. The single-bit `$_..._` gate set the
importer targets first needs no splitting -- each cell is already 1-bit.

### Constants and ports

* `"0"` -> reserved netId **0** (const0), `"1"` -> reserved netId **1**
  (const1), `"x"`/`"z"` -> reserved netId **2** (constX). These ids are seeded
  in the net map before any real net, so they are never reused.
* Yosys integer bit-ids are remapped to a fresh **dense** netId space starting
  at 3, in first-seen order (ports are walked before cells). The Yosys-bit ->
  netId table (`netMap`) keeps the mapping stable so shared ids stay shared.
* A module **input** port becomes an entry in the IR `inputs` dict
  (signalName -> LSB-first netId list); an **output** becomes an entry in
  `outputs`; an **inout** is listed in both (the kernel picks drive direction).
* The CLK net of every sequential cell is collected into the `clocks` list.

## 3. Recommended synthesis recipe

To get a netlist this importer maps cleanly (the single-bit gate set + simple
flip-flops), reduce as far as the gate library:

```tcl
# yosys -p '...'  (or a .ys script)
read_verilog top.v          ;# or read_verilog -sv / read_blif / GHDL plugin for VHDL
hierarchy -check -top top   ;# resolve the design tree, pick the top
proc                        ;# turn always-blocks into netlist constructs
flatten                     ;# one module: simplest IR for a first importer
synth -top top              ;# coarse-grained synthesis ($dff/$add/$mux/...)
techmap                     ;# lower coarse cells toward simple gates/FFs
opt -full                   ;# constant-fold, dedup, drop dead logic
# optional, for the pure gate set (needs a liberty or the built-in mapping):
#   dfflibmap / abc -g AND,OR,XOR,MUX,NAND,NOR   ;# map FFs and combinational to $_..._
write_json -compat-int top.json
```

Notes: `flatten` is recommended until the importer handles module hierarchy.
`abc -g <gates>` (or a target `.lib`) is what actually emits the `$_..._`
single-bit gates; without it `synth` leaves coarse `$and`/`$add`/`$dff` cells
(supported later -- see the mapping table). Keep memories as `$mem_v2` (do not
`memory_collect`-then-bram-map for the software FPGA) so the kernel models them
as block RAM.

## 4. SHARED DIGITAL-NETLIST IR CONTRACT

The importer's `parse` / `parseString` emits **exactly** this dict; the digital
kernel consumes it. Reproduced verbatim:

```
name    <top module name>
nbits   <count of distinct 1-bit nets; net ids are ints; reserve 0=const0, 1=const1>
inputs  dict: signalName -> list of netIds (LSB first)
outputs dict: signalName -> list of netIds (LSB first)
clocks  list of netIds used as clocks
cells   list of {name <inst> type <PRIM> params <dict> conn <dict port->listOfNetIds LSBfirst>}
(LUT params {k init}; DFF params {clkpol rstpol rstval async enable}; MEM params {abits dbits words rdsync})
```

Map Yosys integer bit-ids onto our netId space (keep a Yosys-bit -> netId
table; map "0" -> 0, "1" -> 1).

### Reconciliation notes (for the kernel agent)

* **`nbits` = count including reserved nets.** The importer returns `nbits =
  nextNet`, i.e. it counts net ids `0..nextNet-1` -- the three reserved
  constants (0,1,2) *and* every real net. So `nbits` is the size of the net
  array the kernel must allocate, not the count of *user* nets. The contract
  reserves 0=const0 and 1=const1; the importer additionally reserves **2 =
  constX** for `"x"`/`"z"`. If the kernel expects only 0/1 reserved, treat net 2
  as a fixed const-X (or fold to 0) -- flag if a different convention is wanted.
* **`conn` port keys are normalised to the Schem primitive's pin names**, not
  raw Yosys port names: clocks are emitted as `CLK` (Yosys `$_DFF_*` uses `C`),
  data as `D`, output as `Q`, gates as `A`/`B`/`S`/`Y`. So a DFF's `conn` is
  `{CLK .. D .. Q ..}`.
* **`inout` ports** appear in both `inputs` and `outputs`; the kernel arbitrates
  drive. None occur in the minimal flow.
* **`clocks`** is de-duplicated and currently derived solely from sequential
  cells' `CLK` nets; if a clock is only a top-level input with no FF yet mapped,
  it will not appear until that cell type is supported.
```
