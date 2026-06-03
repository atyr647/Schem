# Virtual Fabric: FPGA Modeling in Schem

## Status: Phase 3–4 Design Document (Research + Design, no engine code yet)

---

## (a) The Key Insight: A Configured FPGA Is Just a Netlist

A programmed FPGA is not magic hardware — it is a fixed netlist of look-up
tables (LUTs), D flip-flops (DFFs), block RAMs, and I/O cells whose
connectivity and initialization values are determined by the bitstream.
Once the bitstream is decoded, the resulting fabric description is structurally
identical to what a synthesis tool emits as a gate-level netlist: nodes,
edges, and per-primitive parameters.

This observation is the architectural foundation for both Phase 3 and Phase 4:

```
Phase 3 (synth path)                   Phase 4 (bitstream path)
─────────────────────────────           ──────────────────────────────────────
Verilog                                 .bin  (iCE40 binary bitstream)
  │ yosys synth_ice40                     │ iceunpack
  ▼                                       ▼
JSON netlist (SB_LUT4, SB_DFF*, …)     .asc  (ASCII tile config)
  │ decode cells + params                 │ bitstream decoder
  ▼                                       ▼
  ╔══════════════════════════════════╗    ╔══════════════════════════════════╗
  ║  Digital Netlist IR              ║    ║  Digital Netlist IR              ║
  ║  (LUT4 with init, DFF with mode, ║    ║  (LUT4 with init, DFF with mode, ║
  ║   BRAM, IO cells, net graph)     ║    ║   BRAM, IO cells, net graph)     ║
  ╚══════════════════════════════════╝    ╚══════════════════════════════════╝
          │                                          │
          └──────────────┬───────────────────────────┘
                         ▼
             Schem clocked-digital sim kernel
             (digseq / zig -digital -cycles N)
```

The **shared sim kernel** already exists: `digseq` and the Zig digital emitter
(`src/backend/zig.tcl` with `-digital -cycles N`) run a clocked boolean
evaluator that carries state across cycles over a netlist of memory + logic
nodes. The FPGA extension adds two new input paths feeding the same kernel —
no new simulator is needed.

**Sources:**
- Project IceStorm overview: http://www.clifford.at/icestorm/
- YosysHQ IceStorm GitHub: https://github.com/YosysHQ/icestorm
- IceStorm readthedocs: https://prjicestorm.readthedocs.io/en/latest/overview.html

---

## (b) iCE40 Primitive Reference and Mapping to Schem IR Primitives

### Target: iCE40 LP/HX Family

The Lattice iCE40 LP/HX family (1K, 4K, 8K logic elements) is the chosen
target because it has the smallest fully open and community-verified bitstream
of any production FPGA, documented by Project IceStorm
(http://www.clifford.at/icestorm/). The HX1K (TQ144 package) is the primary
development target; HX8K is a natural extension using the same tile types.

### Fabric Tile Organization

The FPGA die is divided into tiles arranged in a 2-D grid. There are three
relevant tile types:

| Tile type    | Config bit width | Config rows | Content                         |
|--------------|-----------------|-------------|----------------------------------|
| LOGIC tile   | 54 bits          | 16          | 8 logic cells (LUT4+DFF+carry)  |
| IO tile      | 18 bits          | 16          | 2 IO blocks (SB_IO)             |
| RAM tile     | 42 bits          | 16          | Half of one SB_RAM40_4K         |

A logic tile's 16×54 bit array (864 bits total) encodes the configuration of 8
logic cells plus local routing mux selects. The bits are referenced as
`B_row_[col]` (B0[0] … B15[53]).

Source: IceStorm ASC format documentation,
https://prjicestorm.readthedocs.io/en/latest/format.html

### The Logic Cell (LC)

Each logic tile contains **8 logic cells** (LC_0 through LC_7), arranged
vertically. Each logic cell contains:

1. A **4-input look-up table** (LUT4) — any boolean function of 4 signals.
2. A **D flip-flop** (DFF) — configurable mode (plain/enable/set/reset, sync/async).
3. A **carry unit** — fast ripple carry for arithmetic.

The LUT output and DFF output are routed independently; the LUT output can
bypass the DFF entirely (combinational path) or be registered through it.

Within the tile bitstream, for logic cell N (0–7):

- **LUT init bits** (16 bits): extracted by `icebox.get_lutff_lut_bits(N)`,
  which picks specific bit positions from the tile rows. The function uses
  a reordering index array `[4, 14, 15, 5, 6, 16, 17, 7, 3, 13, 12, 2, 1, 11, 10, 0]`
  applied to the lutff bit group for that cell, yielding the 16-bit LUT_INIT
  constant in the same bit order as the `SB_LUT4.LUT_INIT` parameter.
- **Sequential (DFF) mode bits** (4 bits): extracted by
  `icebox.get_lutff_seq_bits(N)` from bit positions [8, 9, 18, 19] of the
  cell's bit group. These encode: bit[1]=FF_enable (whether the DFF is active
  at all), bit[3]=sync_mode (synchronous vs. asynchronous reset/set), plus
  cell-level NegClk (clock polarity) stored in the tile extra bits.
- **Carry enable**: a separate configuration bit selects whether the carry
  chain propagates through this LC.

Source: icebox_vlog.py analysis,
https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox_vlog.py;
icebox.py source, https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox.py

### iCE40 Primitive → Schem IR Primitive Mapping

All cell semantics below are sourced from the official Yosys iCE40 simulation
model: https://github.com/YosysHQ/yosys/blob/main/techlibs/ice40/cells_sim.v

#### SB_LUT4

```
Ports:    I0, I1, I2, I3 (inputs), O (output)
Params:   LUT_INIT [15:0]
Eval:     index = {I3,I2,I1,I0} (4-bit);  O = LUT_INIT[index]
```

Behavioral Verilog (from cells_sim.v):
```verilog
wire [7:0] s3 = I3 ? LUT_INIT[15:8] : LUT_INIT[7:0];
wire [3:0] s2 = I2 ? s3[7:4] : s3[3:0];
wire [1:0] s1 = I1 ? s2[3:2] : s2[1:0];
assign O = I0 ? s1[1] : s1[0];
```

**Schem IR mapping:** `lut4` primitive with `init` = 16-bit integer. Eval is
a single table lookup: `O = (init >> {I3,I2,I1,I0}) & 1`. This is one
instruction in the Zig digital emitter.

#### SB_CARRY

```
Ports:    I0, I1, CI (inputs), CO (output)
Eval:     CO = (I0 & I1) | (I1 & CI) | (CI & I0)
```

**Schem IR mapping:** `carry` primitive, or inlined as a 3-input majority
function. In practice, the carry chain is part of the same logic cell as the
LUT, so the IR can fold it as a separate node `carry(I0, I1, CI)` driven from
the two LUT inputs and the prior cell's carry-out.

#### SB_DFF (plain — no enable, no set/reset)

```
Ports:    C (clock), D (input), Q (output)
Eval:     always @(posedge C) Q <= D
```

**Schem IR mapping:** `dff` node. On each rising clock edge: `Q_next = D`.

#### SB_DFFE (clock enable)

```
Ports:    C, E (enable), D, Q
Eval:     always @(posedge C) if (E) Q <= D
```

**Schem IR mapping:** `dff` with `enable` signal. `Q_next = E ? D : Q`.

#### SB_DFFSR (synchronous reset — active high, priority over D)

```
Ports:    C, R (reset), D, Q
Eval:     always @(posedge C) if (R) Q <= 0; else Q <= D
```

**Schem IR mapping:** `dff` with `srst` (synchronous reset). `Q_next = R ? 0 : D`.

#### SB_DFFR (asynchronous reset)

```
Ports:    C, R, D, Q
Eval:     always @(posedge C, posedge R) if (R) Q <= 0; else Q <= D
```

**Schem IR mapping:** `dff` with `arst` (async reset). R overrides outside
clock edge.

#### SB_DFFSS (synchronous set)

```
Ports:    C, S, D, Q
Eval:     always @(posedge C) if (S) Q <= 1; else Q <= D
```

**Schem IR mapping:** `dff` with `sset`.

#### SB_DFFS (asynchronous set)

```
Ports:    C, S, D, Q
Eval:     always @(posedge C, posedge S) if (S) Q <= 1; else Q <= D
```

**Schem IR mapping:** `dff` with `aset`.

#### SB_DFFESR (enable + synchronous reset)

```
Ports:    C, E, R, D, Q
Eval:     always @(posedge C) if (E) begin if (R) Q <= 0; else Q <= D; end
```

**Schem IR mapping:** `dff` with `enable` + `srst`. `Q_next = E ? (R ? 0 : D) : Q`.

#### SB_DFFER (enable + asynchronous reset)

```
Ports:    C, E, R, D, Q
Eval:     always @(posedge C, posedge R) if (R) Q <= 0; else if (E) Q <= D
```

**Schem IR mapping:** `dff` with `enable` + `arst`.

#### SB_DFFESS / SB_DFFES (enable + set variants)

Analogous to above with S (set-to-1) instead of R. Schem IR: `dff` with
`enable` + `sset` or `aset`.

#### SB_DFFN / SB_DFFNE / SB_DFFNSR (negative-edge variants)

```
Eval:     always @(negedge C) ...   (same logic as posedge variants)
```

**Schem IR mapping:** `dff` with `negedge` flag. The NegClk configuration
bit in the tile's extra bits selects falling-edge triggering.

**Summary table — all DFF variants:**

| Cell          | Edge  | Enable | Set/Reset       |
|---------------|-------|--------|-----------------|
| SB_DFF        | pos   | —      | —               |
| SB_DFFE       | pos   | yes    | —               |
| SB_DFFSR      | pos   | —      | sync reset      |
| SB_DFFR       | pos   | —      | async reset     |
| SB_DFFSS      | pos   | —      | sync set        |
| SB_DFFS       | pos   | —      | async set       |
| SB_DFFESR     | pos   | yes    | sync reset      |
| SB_DFFER      | pos   | yes    | async reset     |
| SB_DFFESS     | pos   | yes    | sync set        |
| SB_DFFES      | pos   | yes    | async set       |
| SB_DFFN       | neg   | —      | —               |
| SB_DFFNE      | neg   | yes    | —               |
| SB_DFFNSR     | neg   | —      | sync reset      |

All DFF variants initialize to Q=0 on power-up. No variant supports both set
and reset simultaneously.

#### SB_RAM40_4K — Block RAM

4 Kbit true dual-port synchronous RAM. Key parameters and ports:

```
Total capacity:  4096 bits = 4 Kbit
Aspect ratios:   256×16, 512×8, 1024×4, 2048×2  (selected by READ_MODE/WRITE_MODE)

Write port:
  WCLK    — write clock (posedge, or negedge for SB_RAM40_4KNW)
  WE      — write enable (active high)
  WCLKE   — write clock enable
  WADDR[10:0] — write address
  WDATA[15:0] — write data
  MASK[15:0]  — bit-write mask (active low — 0 = write, 1 = mask)

Read port:
  RCLK    — read clock (posedge, or negedge for SB_RAM40_4KNR)
  RE      — read enable (active high)
  RCLKE   — read clock enable
  RADDR[10:0] — read address
  RDATA[15:0] — read data output

Parameters:
  READ_MODE  [1:0] — selects read data width: 0=256×16, 1=512×8, 2=1024×4, 3=2048×2
  WRITE_MODE [1:0] — selects write data width (same encoding)
  INIT_*     — 256 bits of initialization data per INIT word (INIT_0..INIT_F)
  NEGCLK_R, NEGCLK_W — invert respective clocks

Variants by clock polarity:
  SB_RAM40_4K    — both clocks posedge
  SB_RAM40_4KNR  — read negedge, write posedge
  SB_RAM40_4KNW  — read posedge, write negedge
  SB_RAM40_4KNRNW — both clocks negedge
```

**Schem IR mapping:** `bram` node with two synchronous ports (read/write),
`init` data, and `mode` determining address/data width split. The existing IR
`memory` class (abits/dbits, WE, CLK, data-in/data-out) extends naturally to
dual-port with separate RCLK/WCLK. The BRAM sits in RAMB/RAMT tile pairs in
the fabric.

Source: Lattice iCE40 Memory Usage Guide,
https://www.latticesemi.com/-/media/LatticeSemi/Documents/ApplicationNotes/MO/MemoryUsageGuideforiCE40Devices.ashx

#### SB_IO — Programmable I/O

```
Ports (key subset):
  PACKAGE_PIN       — physical pad (inout)
  D_OUT_0           — data to drive on rising OUTPUT_CLK edge
  D_OUT_1           — data to drive on falling OUTPUT_CLK edge (DDR mode)
  D_IN_0            — sampled input on rising INPUT_CLK edge
  D_IN_1            — sampled input on falling INPUT_CLK edge
  OUTPUT_ENABLE     — tri-state control
  INPUT_CLK, OUTPUT_CLK — separate clocks for input/output registers
  CLOCK_ENABLE      — clock enable for both registers
  LATCH_INPUT_VALUE — hold input value (glitch filter)

Parameters:
  PIN_TYPE [5:0]    — encodes output mode (bits[1:0]) and input mode (bits[5:2])
  PULLUP            — enable internal pull-up
  NEG_TRIGGER       — invert clock polarity
  IO_STANDARD       — voltage standard (SB_LVCMOS, etc.)
```

**Schem IR mapping:** `io` node. In simulation, SB_IO is modeled as a
registered input buffer (D_IN_0 ← PACKAGE_PIN on clock) or output buffer
(PACKAGE_PIN ← D_OUT_0 on clock when OUTPUT_ENABLE). Pin stimulus is driven
externally as test vectors.

#### SB_GB — Global Buffer

```
Ports:    USER_SIGNAL_TO_GLOBAL_BUFFER (input), GLOBAL_BUFFER_OUTPUT (output)
Eval:     assign GLOBAL_BUFFER_OUTPUT = USER_SIGNAL_TO_GLOBAL_BUFFER
```

The iCE40 has 8 global networks, each driven from a dedicated IO pin or fabric
signal routed through an `SB_GB` (or `SB_GB_IO`). Global nets reach every
logic tile in the fabric with near-zero skew; they are the primary clock
distribution mechanism. In the sim, a global net is simply a named high-fanout
wire — no special modeling needed beyond marking it as a clock net for the
evaluation order.

**Schem IR mapping:** `global_net` — a net that is pre-evaluated before any
logic cell that consumes it, ensuring consistent clock delivery across the
netlist.

---

## (c) Phase 3: The synth_ice40 Arch-Cell Path

### What Phase 3 Does

Phase 3 is the **software-only path**: take an ordinary Verilog design, run
the standard open-source synthesis and P&R tools to produce a placed-and-routed
netlist of iCE40 primitives, and import that netlist into Schem's sim kernel.
No bitstream is involved; the tools are run at build/design time.

This is the easiest correctness path because the netlist comes directly from
the synthesis tool with full cell semantics — no reverse-engineering of bit
positions is needed.

### Tool Chain

```sh
# 1. Synthesize to iCE40 arch cells (JSON netlist)
yosys -p 'synth_ice40 -top blinky -json blinky.json' blinky.v

# 2. Place and route (requires a .pcf pin-constraint file)
nextpnr-ice40 --hx1k --json blinky.json --pcf blinky.pcf --asc blinky.asc

# 3. (For Phase 3 only, the .asc output is used as input to Phase 4;
#    Phase 3 stops here and uses blinky.json directly.)
```

- **yosys** ≥ 0.33 (the `synth_ice40` command). Available via OS packages or
  https://github.com/YosysHQ/yosys.
- **nextpnr-ice40** — for full P&R. Needed for Phase 4 oracle testing but not
  strictly for Phase 3 if feeding a pre-synthesized JSON.
  https://github.com/YosysHQ/nextpnr
- All tools are **optional/build-time** — if absent, the FPGA path simply is
  not available; the rest of Schem is unaffected.

### What synth_ice40 Emits

The `synth_ice40` command is a sequence of Yosys passes:

```
begin → flatten → coarse → map_ram → map_ffram → map_gates
     → map_ffs → map_luts → map_cells → check → json
```

The output JSON contains a module whose cells are all iCE40 arch-level
primitives. After `map_luts` + `map_cells`, the cells present are:

| Yosys arch cell    | Meaning                          | Phase 3 IR node |
|--------------------|----------------------------------|-----------------|
| `SB_LUT4`          | 4-input LUT with `LUT_INIT`      | `lut4`          |
| `SB_CARRY`         | ripple carry                     | `carry`         |
| `SB_DFF`           | plain DFF                        | `dff`           |
| `SB_DFFE`          | DFF + clock enable               | `dff`+enable    |
| `SB_DFFSR`         | DFF + sync reset                 | `dff`+srst      |
| `SB_DFFR`          | DFF + async reset                | `dff`+arst      |
| `SB_DFFSS`         | DFF + sync set                   | `dff`+sset      |
| `SB_DFFS`          | DFF + async set                  | `dff`+aset      |
| `SB_DFFESR`        | DFF + enable + sync reset        | `dff`+E+srst    |
| `SB_DFFER`         | DFF + enable + async reset       | `dff`+E+arst    |
| `SB_DFFESS`        | DFF + enable + sync set          | `dff`+E+sset    |
| `SB_DFFES`         | DFF + enable + async set         | `dff`+E+aset    |
| `SB_DFFN*`         | negative-edge variants           | `dff`+negedge   |
| `SB_RAM40_4K`      | 4 Kbit block RAM                 | `bram`          |
| `SB_IO`            | programmable I/O pad             | `io`            |
| `SB_GB` / `SB_GB_IO` | global buffer/clock           | `global_net`    |

DFF variants that include clock-enable are disabled by default; pass `-nodffe`
to suppress. Block RAM inference is enabled by default; pass `-nobram` to use
distributed LUT RAM instead. Carry chains can be disabled with `-nocarry`.

### JSON Netlist Import

The Yosys JSON format is straightforward to parse: each module has a `cells`
dict where each entry has a `type` (the arch cell name), `parameters` (e.g.
`LUT_INIT`), and `connections` (port → net-ID list). A Phase 3 importer in
Tcl (or Zig) walks this structure and builds the digital netlist IR directly:

```tcl
# Pseudocode for JSON → IR import
foreach {cell_name cell} [dict get $json modules $top_module cells] {
    set type [dict get $cell type]
    set params [dict get $cell parameters]
    set conns [dict get $cell connections]
    switch $type {
        SB_LUT4   { ir_add_lut4 $cell_name [lut_init_from_bits $params] $conns }
        SB_DFF    { ir_add_dff  $cell_name plain $conns }
        SB_DFFE   { ir_add_dff  $cell_name enable $conns }
        SB_DFFSR  { ir_add_dff  $cell_name srst $conns }
        ...
        SB_RAM40_4K { ir_add_bram $cell_name $params $conns }
        SB_IO     { ir_add_io   $cell_name $params $conns }
    }
}
```

The existing JSON support in `src/io/netlist.tcl` and `src/io/compile.tcl`
provides the structural foundation. The FPGA IR extension is a new class of
nodes layered above the existing element taxonomy.

**Note on the counter.synth.json experiment:** The file at
`experiments/fpga/phase0/counter.synth.json` shows Yosys output at the
`flatten`/`coarse` stage — it still contains generic cells (`$_SDFF_PP0_`,
`$_XOR_`, `$_AND_`) rather than final arch cells. Running
`synth_ice40` to completion (through `map_luts`) would replace these with
`SB_LUT4` + `SB_DFFSR` etc. The Phase 3 importer targets the fully-mapped
output.

---

## (d) Phase 4: Bitstream Path — .asc Decode → Tile Config → Fabric Netlist

### Overview

Phase 4 takes a compiled `.bin` file — a design that has been synthesized,
placed, and routed for actual silicon — and reconstructs the same digital
netlist that Phase 3 builds from JSON. This validates that both paths converge
to the same IR, and enables loading any existing iCE40 `.bin` without access
to source Verilog.

### Step 1: .bin → .asc (iceunpack)

The iCE40 binary bitstream is a sequence of bank-programming commands followed
by CRAM (configuration SRAM) and BRAM data bytes. The binary format begins
with the byte sequence `0xFF 0x00` followed by zero-terminated comment
strings, then `0x00 0xFF`, and the magic token `0x7EAA997E` before the
command stream.

`iceunpack` (part of the IceStorm tools) converts a `.bin` to the ASCII `.asc`
format. All other IceStorm tools operate on `.asc` exclusively. The `.asc`
format is human-readable and is the primary decoding target:

```
.device hx1k
.comment Blinky design placed by nextpnr
.logic_tile 3 5
000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000
...   (16 rows × 54 zero/one characters)
.logic_tile 3 6
...
.io_tile 0 5
...  (16 rows × 18 characters)
.ram_tile 3 4
...  (16 rows × 42 characters)
.extra_bits
1 0 0
...
.sym counter_q[0] lutff_3/out
```

Source: https://prjicestorm.readthedocs.io/en/latest/format.html

### Step 2: .asc Tile Sections → Per-Cell Configuration

Each `.logic_tile X Y` section contains 864 configuration bits for 8 logic
cells plus routing mux selects. The IceStorm `icebox` Python library
(https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox.py) provides
the authoritative bit-position database. The decoder must replicate this
logic:

**For each logic cell LC_N in a logic tile:**

1. **Extract lutff_bits**: the 20 raw bits belonging to cell N from the 16×54
   array. Cell N's bits start at a known row offset determined by N's position
   in the column.

2. **Decode LUT init (16 bits):** Apply the reordering index
   `[4, 14, 15, 5, 6, 16, 17, 7, 3, 13, 12, 2, 1, 11, 10, 0]` to the
   lutff_bits to recover `LUT_INIT[15:0]` in the same bit order as
   `SB_LUT4.LUT_INIT`. This is `icebox.get_lutff_lut_bits(N)`.

3. **Decode DFF mode (4 bits):** Bits at indices `[8, 9, 18, 19]` of the
   lutff_bits give `seq_bits[0:3]`. From `icebox_vlog.py`:
   - `seq_bits[1] == '1'`: this LC has an active DFF (FF_enable).
   - `seq_bits[3] == '1'`: synchronous mode (reset/set is clocked);
     `seq_bits[3] == '0'`: asynchronous mode.
   - Carry enable: a separate per-cell carry bit.
   - Clock polarity (NegClk): stored in the tile's `.extra_bits` section,
     one bit per logic column.

4. **Determine reset/set type:** `icebox_vlog.py` checks further seq_bits to
   distinguish reset (→0) vs. set (→1). The exact bit assignments are in the
   `iceboxdb` database embedded in the icebox library.

5. **Decode routing mux selects:** The non-LUT/DFF bits of the tile config
   encode which of the local wires, span-4 wires, span-12 wires, or carry
   signals are connected to each LC input and output. The `chipdb` (chipdb-1k.txt,
   chipdb-8k.txt, installed by the IceStorm Makefile) contains the full
   enumeration of mux select bit positions for every wire segment in every tile.

### Step 3: Routing → Net Connectivity

This is the hardest part. The routing fabric consists of:

- **Local tracks**: 32 local signals within each logic tile (most connect
  to the 8 LUT outputs and carry signals within the tile).
- **Span-4 wires**: horizontal and vertical segments spanning 4 tiles.
- **Span-12 wires**: longer segments spanning 12 tiles.
- **Global nets**: 8 global clock/signal networks reaching all tiles.

`icebox.group_segments()` builds a union-find structure over all wire segments
that are connected by routing muxes (each driven mux merge means the two segments
share a net). The decoder calls this to produce a net list: a dict mapping net
IDs to lists of `(tile_x, tile_y, port_name)` connection points.

From the net list, the fabric netlist IR is assembled:
- Every `(tile_x, tile_y, LC_N, "out")` segment that drives a net connects
  the output of that LUT/DFF to all LUT inputs in the net.
- Every `(tile_x, tile_y, LC_N, "in_k")` segment in a net connects to the
  corresponding LUT input.
- RAM tiles expose their ports as named segments that participate in the same
  routing system.

**Practical decoder sketch (Tcl/Python):**

```
for each .logic_tile X Y in the .asc:
    for N in 0..7:
        lut_init  = get_lutff_lut_bits(tile_bits, N)   # 16 bits → integer
        seq_bits  = get_lutff_seq_bits(tile_bits, N)   # 4 bits
        dff_mode  = decode_dff_mode(seq_bits, negclk[X,Y])
        carry_en  = get_carry_enable(tile_bits, N)
        ir.add_lut4(id=(X,Y,N), init=lut_init)
        if dff_mode != COMB:
            ir.add_dff(id=(X,Y,N,'ff'), mode=dff_mode)
            ir.connect(lut_out(X,Y,N), dff_d(X,Y,N))

nets = icebox.group_segments(all_tile_bits, chipdb)
for net_id, segments in nets:
    ir.add_net(net_id)
    for seg in segments:
        ir.connect_segment(net_id, seg)

for each .ram_tile pair at (X, Y):
    init_data = decode_bram_init(tile_bits)
    mode      = decode_bram_mode(tile_bits)
    ir.add_bram(id=(X,Y), mode=mode, init=init_data)
```

### Step 4: Fabric Netlist → Sim Kernel

The resulting IR is structurally identical to what Phase 3 produces from JSON.
The same `digseq` / Zig clocked-digital evaluator runs it:

```
for each clock cycle:
    1. Evaluate all LUT4 combinational outputs (topological order)
    2. Evaluate BRAM read ports
    3. Latch all DFF Q values from their D inputs (rising-edge sampling)
    4. Write BRAM write ports
    5. Advance to next cycle
```

Global nets (clock signals) are evaluated first, before any logic that
consumes them, preserving the zero-skew clock semantics.

### Prior Art: icebox_vlog

The `icebox_vlog.py` tool (https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox_vlog.py)
decodes an `.asc` file back to a Verilog netlist of `SB_LUT4`, `SB_DFF*`,
`SB_RAM40_4K`, and `SB_IO` instances. This is direct prior art for the Phase 4
decoder:

- It calls `icebox.get_lutff_lut_bits(N)` to get LUT init bits and
  recursively builds a ternary-expression Verilog assignment for each LUT.
- It calls `icebox.get_lutff_seq_bits(N)` and checks `seq_bits[1]` (DFF
  active) and `seq_bits[3]` (sync/async) to emit `always` blocks.
- It calls `ic.group_segments()` to build nets and generates `wire` declarations.
- It emits `SB_IO` instances for IO tiles, and extracts BRAM INIT_* parameters
  from RAM tiles.

The Schem decoder differs from `icebox_vlog` in that it builds an IR (for the
sim kernel) rather than a Verilog text file, and it does not need to
pretty-print expressions — it only needs the integer LUT_INIT value and the
DFF mode enumeration.

---

## (e) The Oracle: Dual-Path Simulation Agreement

The single most powerful correctness check for both the Phase 3 and Phase 4
implementations is what Schem's existing verification strategy calls
"emit both, run both, diff":

**For any design with a known Verilog source:**

1. **Path A (synth netlist):** Run `synth_ice40` on the Verilog, import the
   JSON, build the IR, simulate N clock cycles with `digseq`, record the output
   vector `V_A[cycle]` for all observable signals.

2. **Path B (bitstream):** Run the full P&R (`nextpnr-ice40` + `icepack`),
   decode the `.bin` back to `.asc` with `iceunpack`, run the Phase 4 decoder
   to build the IR from tile bits, simulate the same N cycles with `digseq`,
   record `V_B[cycle]`.

3. **Assert:** `V_A[cycle] == V_B[cycle]` for all cycles and all signals.

This single check validates the entire Phase 4 pipeline because Path A is
the authoritative reference (it comes directly from Yosys's verified tech-mapping)
and Path B must agree with it cycle-for-cycle. Any bit-position error in the
LUT decoder, any DFF mode misidentification, or any routing connectivity mistake
will cause observable divergence in the output vectors. The check catches decoder
bugs, routing omissions, and DFF mode encoding errors simultaneously, without
requiring manual inspection of intermediate state.

This matches Schem's existing verification ethos exactly: the `dcref` / `digref`
/ `digseq` Tcl references are the trusted oracles that the compiled Zig output
must match, and the test suite (`tests/test_cir.tcl`) asserts cycle-for-cycle
agreement. The FPGA oracle extends this pattern to a new domain.

---

## (f) Phased Task Breakdown and Milestones

### External Tools Required (all optional/build-time)

| Tool | Package | Required for | Source |
|------|---------|--------------|--------|
| `yosys` | `yosys` | Phase 3 + 4 | https://github.com/YosysHQ/yosys |
| `nextpnr-ice40` | `nextpnr-ice40` | Phase 4 P&R | https://github.com/YosysHQ/nextpnr |
| `icepack`/`iceunpack` | `fpga-icestorm` | Phase 4 decode | https://github.com/YosysHQ/icestorm |
| `iceprog` | `fpga-icestorm` | Hardware (optional) | same |
| Python 3 + icebox | included with icestorm | Phase 4 bit decode | same |
| `iverilog` | `iverilog` | Oracle RTL sim | http://iverilog.icarus.com/ |

Detection: `info exists env(SCHEM_YOSYS)` or `exec which yosys`. If absent,
FPGA tests skip cleanly — same pattern as `SCHEM_ZIG`.

### Phase 3A — JSON Importer + LUT/DFF Sim (Milestone: blinky counter)

**Goal:** Load a synthesized-but-not-placed JSON netlist and simulate it.

Tasks:
1. Define the digital netlist IR extension: `lut4`, `dff`, `carry`, `bram`, `io` node types, their parameter schemas, and their eval semantics.
2. Write the JSON importer (`src/fpga/json_import.tcl`): parse Yosys JSON, emit IR nodes.
3. Extend `digseq` (or write a parallel `fpgaseq` evaluator) to handle `lut4` and the full DFF variant matrix.
4. **Test:** Import `experiments/fpga/phase0/counter.synth.json` (re-run `synth_ice40` to get final arch cells), simulate 10 clock cycles, check counter increments.
5. **Milestone:** blinky LED counter (8-bit, resets on rst) runs correctly in sim from JSON.

### Phase 3B — BRAM + IO Simulation

Tasks:
1. Add `bram` dual-port eval (READ_MODE/WRITE_MODE aspect ratio, INIT data).
2. Add `io` node: pin stimulus driven by test vector; D_IN_0 sampled on clock.
3. **Test:** A design using SB_RAM40_4K (e.g., a lookup table in ROM mode) simulates correctly from JSON.
4. **Milestone:** A small Verilog ROM-lookup design runs cycle-accurately from the JSON netlist.

### Phase 4A — .asc Decoder (Milestone: LUT/DFF fabric from bitstream)

Tasks:
1. Write `.asc` parser (`src/fpga/asc_parse.tcl` or Python helper): parse tile headers, tile bit arrays, extra_bits, sym table.
2. Port or call `icebox.get_lutff_lut_bits` / `get_lutff_seq_bits` logic into Tcl (or invoke Python subprocess for the bit-position database).
3. Implement DFF mode decoder from seq_bits + negclk extra_bits.
4. **Test (LUT/DFF only):** Decode the blinky `.asc`, reconstruct LUT inits and DFF modes, compare against the Phase 3A JSON import of the same design → must agree.
5. **Milestone:** LUT + DFF fabric extracted from bitstream, oracle test passes for blinky.

### Phase 4B — Routing Decode (Milestone: multi-tile design)

Tasks:
1. Integrate `icebox.group_segments()` (or call Python subprocess): build net list from mux selects + chipdb.
2. Wire the net list into the IR: connect LUT inputs/outputs, carry chains, BRAM ports, IO pins.
3. **Test:** Simulate a multi-tile design (e.g., 8-bit counter with reset) via decoded bitstream netlist; oracle-compare against JSON netlist.
4. **Milestone:** Full routing correctly reconstructed; counter runs cycle-accurately from `.bin`.

### Phase 4C — BRAM Bitstream Decode + UART Milestone

Tasks:
1. Decode RAM tile init data (BRAM INIT_* parameters from `.ram_tile` sections).
2. Simulate a design with SB_RAM40_4K (e.g., a simple UART with baud-rate ROM).
3. **Oracle test:** `V_A` (from JSON netlist) == `V_B` (from `.bin` decode) for all cycles.
4. **Milestone:** UART transmitter bit-accurate in Schem sim, fed from decoded bitstream.

### Phase 4D — PicoSOC (Stretch Milestone)

Tasks:
1. Attempt to load a PicoSOC bitstream (https://github.com/cliffordwolf/picorv32/tree/master/picosoc).
2. This is a ~3 KLUT design; routing decode complexity scales up significantly.
3. Run the RISC-V core for a small number of cycles, compare instruction fetch/decode signals against an icebox_vlog-generated Icarus Verilog simulation.
4. **Note:** This milestone primarily tests scaling and routing decode robustness. Performance will require the Zig compiled path for any non-trivial cycle count.

---

## (g) Honest Risks

### Risk 1: Bitstream is Reverse-Engineered and Architecture-Specific

The IceStorm bit-position database is a community reverse-engineering effort,
not an official Lattice document. While it is mature and trusted for iCE40
LP/HX 1K/4K/8K, it is not complete for all iCE40 variants (UltraPlus has
partial coverage). The bit assignments are correct for the target devices but
would need new reverse-engineering work for any other FPGA family (ECP5,
iCE40-UP5K extensions, etc.).

**Mitigation:** Scope strictly to iCE40 HX1K and HX8K for Phase 4. The
Phase 3 synth path (JSON) is architecture-agnostic and works with any Yosys
target as long as the primitives are in the LUT/DFF/BRAM vocabulary.

### Risk 2: Routing Modeling Is the Hard Part

The routing fabric (span-4, span-12, local groups, carry chains) is complex.
Fully decoding routing requires either embedding the entire `chipdb` database
or calling out to the `icebox` Python library. Errors in routing connectivity
produce incorrect simulation results that can be subtle (wrong fanout, missing
connection) and hard to diagnose without the oracle.

**Mitigation:** Use the oracle check aggressively — any routing error will
cause `V_A != V_B` and surface immediately. Consider making Phase 4 invoke
`icebox_vlog.py` as a subprocess to get a Verilog netlist, then import that
Verilog netlist rather than directly decoding bits, deferring the routing
decode problem to a later phase. This "Verilog bridge" would still validate
the sim kernel against a known-good netlist.

### Risk 3: Performance Requires the Compiled Path

The Tcl-level `digseq` evaluator is adequate for hundreds of cycles on designs
with tens of LUTs (blinky, counter) but will not scale to real FPGA designs
(thousands of LUTs, millions of cycles). PicoSOC or any CPU core needs the Zig
compiled path to be tractable.

**Mitigation:** Phase 3A and 3B validate correctness at Tcl speed. The Zig
`-digital -cycles N` emitter already exists and handles LUT/DFF semantics once
the IR extension is defined. The compiled path is the production target;
Tcl is the oracle/reference only.

---

## References

- Project IceStorm: http://www.clifford.at/icestorm/
- IceStorm GitHub: https://github.com/YosysHQ/icestorm
- IceStorm readthedocs: https://prjicestorm.readthedocs.io/en/latest/overview.html
- IceStorm ASC format: https://prjicestorm.readthedocs.io/en/latest/format.html
- IO Tile Documentation: https://prjicestorm.readthedocs.io/en/latest/io_tile.html
- iCE40 HX1K tile viewer: https://prjicestorm.readthedocs.io/en/latest/_static/bitdocs-1k/index.html
- Yosys cells_sim.v (iCE40): https://github.com/YosysHQ/yosys/blob/main/techlibs/ice40/cells_sim.v
- synth_ice40 command reference: https://yosyshq.readthedocs.io/projects/yosys/en/v0.51/cmd/synth_ice40.html
- icebox.py source: https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox.py
- icebox_vlog.py source: https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox_vlog.py
- nextpnr GitHub: https://github.com/YosysHQ/nextpnr
- Yosys+nextpnr paper: https://arxiv.org/abs/1903.10407
- iCE40 Memory Usage Guide: https://www.latticesemi.com/-/media/LatticeSemi/Documents/ApplicationNotes/MO/MemoryUsageGuideforiCE40Devices.ashx
- EE Times IceStorm article: https://www.eetimes.com/icestorm-reverse-engineering-the-lattice-ice40-bitstream/
- Mantle iCE40 docs: https://magma-mantle.readthedocs.io/en/stable/ice40/
