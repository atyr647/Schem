# iCE40 Fabric Primitives Reference

This document is the focused primitive reference for the Schem iCE40 virtual
fabric (see `docs/FABRIC.md` for architecture and design context). It lists
every iCE40 primitive targeted in Phase 3–4, its configuration parameters,
and the exact eval semantics that the sim kernel implements.

All cell port lists and behavioral semantics are sourced from the official
Yosys iCE40 simulation model:
https://github.com/YosysHQ/yosys/blob/main/techlibs/ice40/cells_sim.v

---

## Primitive Vocabulary

The sim kernel uses four base primitive kinds, each mapping one or more iCE40
cells:

| Kernel kind  | iCE40 cells                                   | Stateful |
|--------------|-----------------------------------------------|----------|
| `lut4`       | `SB_LUT4`                                     | no       |
| `carry`      | `SB_CARRY`                                    | no       |
| `dff`        | `SB_DFF*` (all 14 variants)                   | yes      |
| `bram`       | `SB_RAM40_4K` (+ NR/NW/NRNW clock variants)   | yes      |
| `io`         | `SB_IO`, `SB_GB_IO`                           | yes      |
| `global_net` | `SB_GB`                                       | no       |

---

## SB_LUT4 — 4-Input Look-Up Table

**iCE40 arch cell.** Maps to kernel kind `lut4`.

### Configuration Parameters

| Parameter     | Width | Meaning                                          |
|---------------|-------|--------------------------------------------------|
| `LUT_INIT`    | 16    | Truth-table encoding. Bit `LUT_INIT[i]` is the output when `{I3,I2,I1,I0} == i`. |

### Ports

| Port | Dir | Width | Description        |
|------|-----|-------|--------------------|
| `I0` | in  | 1     | LUT input 0 (LSB of address) |
| `I1` | in  | 1     | LUT input 1        |
| `I2` | in  | 1     | LUT input 2        |
| `I3` | in  | 1     | LUT input 3 (MSB of address) |
| `O`  | out | 1     | Combinational output |

### Eval Semantics

```
index = (I3 << 3) | (I2 << 2) | (I1 << 1) | I0    ; 4-bit integer
O     = (LUT_INIT >> index) & 1
```

Equivalently (from cells_sim.v):
```verilog
wire [7:0] s3 = I3 ? LUT_INIT[15:8] : LUT_INIT[7:0];
wire [3:0] s2 = I2 ? s3[7:4]        : s3[3:0];
wire [1:0] s1 = I1 ? s2[3:2]        : s2[1:0];
assign O      = I0 ? s1[1]           : s1[0];
```

### Bitstream Encoding (Phase 4)

Within a logic tile's 16×54 bit array, for logic cell N (0–7), the 16 LUT
init bits are extracted by `icebox.get_lutff_lut_bits(N)`. This function
selects 16 bits from the cell's raw bit group using the reordering index:

```
raw_indices = [4, 14, 15, 5, 6, 16, 17, 7, 3, 13, 12, 2, 1, 11, 10, 0]
LUT_INIT[k] = lutff_bits[raw_indices[k]]   for k in 0..15
```

The resulting integer is the `LUT_INIT` parameter in the same encoding as the
`SB_LUT4.LUT_INIT` Verilog parameter.

### Example

`LUT_INIT = 16'h6996` implements XOR of all four inputs (parity).
`LUT_INIT = 16'h8000` is a 4-input AND (output 1 only when I3=I2=I1=I0=1).

---

## SB_CARRY — Ripple Carry Unit

**iCE40 arch cell.** Maps to kernel kind `carry`. In the physical fabric,
each logic cell has one carry unit that propagates carry upward within the
tile column.

### Configuration Parameters

None. The carry function is fixed.

### Ports

| Port | Dir | Width | Description                                   |
|------|-----|-------|-----------------------------------------------|
| `I0` | in  | 1     | First operand bit (typically LUT input I0)    |
| `I1` | in  | 1     | Second operand bit (typically LUT input I1)   |
| `CI` | in  | 1     | Carry-in from previous LC in the column       |
| `CO` | out | 1     | Carry-out to next LC                          |

### Eval Semantics

```
CO = (I0 & I1) | (I1 & CI) | (CI & I0)
```

This is the carry-generate/propagate logic: CO is 1 if at least two of the
three inputs are 1. Equivalent to a majority-of-three function.

### Bitstream Encoding (Phase 4)

A per-cell carry-enable bit in the tile config selects whether the carry
chain is active through this cell. When inactive, CI is tied to 0 (or the
carry-out is unused). The carry chain only makes sense vertically within
one tile column; it does not cross tile boundaries in the basic iCE40 fabric.

---

## SB_DFF — D Flip-Flop (Plain)

**iCE40 arch cell.** Maps to kernel kind `dff`. This is the base variant;
all other `SB_DFF*` cells are extensions of this with additional control inputs.

### Configuration Parameters

None for the base cell. The DFF always resets to Q=0 at power-on.

### Ports

| Port | Dir | Width | Description          |
|------|-----|-------|----------------------|
| `C`  | in  | 1     | Clock (rising edge)  |
| `D`  | in  | 1     | Data input           |
| `Q`  | out | 1     | Registered output    |

### Eval Semantics

```
on rising edge of C:
    Q <= D
```

State persists between clock edges. Initial state Q=0.

### Bitstream Encoding (Phase 4)

`icebox.get_lutff_seq_bits(N)` returns 4 bits from indices `[8, 9, 18, 19]`
of the cell's lutff_bits. `seq_bits[1] == '1'` means this LC has an active DFF
(the LUT output is registered rather than passed through combinationally).
The clock edge polarity (posedge vs. negedge) is stored in the tile's
`.extra_bits` section as a NegClk bit, one per tile column.

---

## SB_DFFE — DFF with Clock Enable

### Additional Port

| Port | Dir | Width | Description                       |
|------|-----|-------|-----------------------------------|
| `E`  | in  | 1     | Clock enable (1 = update Q, 0 = hold) |

### Eval Semantics

```
on rising edge of C:
    if E:
        Q <= D
    else:
        Q <= Q   (hold)
```

### Bitstream Encoding (Phase 4)

Clock-enable is encoded in additional seq_bits beyond the base DFF enable bit.
Yosys emits `SB_DFFE` when `-nodffe` is NOT passed to `synth_ice40`.

---

## SB_DFFSR — DFF with Synchronous Reset (active-high, priority)

### Additional Port

| Port | Dir | Width | Description                          |
|------|-----|-------|--------------------------------------|
| `R`  | in  | 1     | Synchronous reset (1 → forces Q=0)   |

### Eval Semantics

```
on rising edge of C:
    if R:
        Q <= 0
    else:
        Q <= D
```

Reset has priority over D. Reset is sampled at the clock edge (synchronous).

---

## SB_DFFR — DFF with Asynchronous Reset

### Additional Port

| Port | Dir | Width | Description                               |
|------|-----|-------|-------------------------------------------|
| `R`  | in  | 1     | Async reset (1 → forces Q=0 immediately)  |

### Eval Semantics

```
on posedge C or posedge R:
    if R:
        Q <= 0
    else:
        Q <= D
```

R overrides outside of the clock edge. In a cycle-accurate model, async reset
is evaluated at the combinational stage: if R=1, Q is forced to 0 regardless
of clock.

### Bitstream Encoding (Phase 4)

`seq_bits[3]` distinguishes synchronous (`seq_bits[3]='1'`) from asynchronous
(`seq_bits[3]='0'`) mode, per `icebox_vlog.py` analysis.

---

## SB_DFFSS — DFF with Synchronous Set

### Additional Port

| Port | Dir | Width | Description                          |
|------|-----|-------|--------------------------------------|
| `S`  | in  | 1     | Synchronous set (1 → forces Q=1)     |

### Eval Semantics

```
on rising edge of C:
    if S:
        Q <= 1
    else:
        Q <= D
```

---

## SB_DFFS — DFF with Asynchronous Set

### Additional Port

| Port | Dir | Width | Description                                |
|------|-----|-------|--------------------------------------------|
| `S`  | in  | 1     | Async set (1 → forces Q=1 immediately)     |

### Eval Semantics

```
on posedge C or posedge S:
    if S:
        Q <= 1
    else:
        Q <= D
```

---

## SB_DFFESR — DFF with Clock Enable + Synchronous Reset

### Additional Ports

| Port | Dir | Width | Description        |
|------|-----|-------|--------------------|
| `E`  | in  | 1     | Clock enable       |
| `R`  | in  | 1     | Synchronous reset  |

### Eval Semantics

```
on rising edge of C:
    if E:
        if R:
            Q <= 0
        else:
            Q <= D
    else:
        Q <= Q   (hold)
```

Reset priority is inside the enable gate: R only applies when E=1.

---

## SB_DFFER — DFF with Clock Enable + Asynchronous Reset

### Additional Ports

| Port | Dir | Width | Description       |
|------|-----|-------|-------------------|
| `E`  | in  | 1     | Clock enable      |
| `R`  | in  | 1     | Async reset       |

### Eval Semantics

```
on posedge C or posedge R:
    if R:
        Q <= 0
    else if E:
        Q <= D
    else:
        Q <= Q   (hold)
```

Async reset has absolute priority over enable.

---

## SB_DFFESS — DFF with Clock Enable + Synchronous Set

### Additional Ports

| Port | Dir | Width | Description      |
|------|-----|-------|------------------|
| `E`  | in  | 1     | Clock enable     |
| `S`  | in  | 1     | Synchronous set  |

### Eval Semantics

```
on rising edge of C:
    if E:
        if S:
            Q <= 1
        else:
            Q <= D
    else:
        Q <= Q
```

---

## SB_DFFES — DFF with Clock Enable + Asynchronous Set

### Additional Ports

| Port | Dir | Width | Description   |
|------|-----|-------|---------------|
| `E`  | in  | 1     | Clock enable  |
| `S`  | in  | 1     | Async set     |

### Eval Semantics

```
on posedge C or posedge S:
    if S:
        Q <= 1
    else if E:
        Q <= D
    else:
        Q <= Q
```

---

## Negative-Edge DFF Variants

The following cells are identical to their positive-edge counterparts except
they trigger on the **falling** edge of C. Schem IR represents this with
a `negedge` flag on the `dff` node.

| Cell       | Positive-edge base | Additional controls |
|------------|--------------------|---------------------|
| `SB_DFFN`  | `SB_DFF`           | none                |
| `SB_DFFNE` | `SB_DFFE`          | clock enable        |
| `SB_DFFNSR`| `SB_DFFSR`         | sync reset          |

(Further negedge variants with set/enable/async are possible but less common
in synth_ice40 output; the pattern extends identically.)

**Eval rule:** Replace `on posedge C` with `on negedge C` in the respective
positive-edge variant above.

**Bitstream:** The NegClk extra bit in the `.asc` file inverts the clock for
the entire tile column. `icebox_vlog.py` reads this from the tile's extra_bits
and emits `always @(negedge C)` instead of `always @(posedge C)`.

---

## DFF Variant Summary Table

| Cell          | Edge  | Enable | Set/Reset       | Sync/Async  |
|---------------|-------|--------|-----------------|-------------|
| `SB_DFF`      | pos   | —      | —               | —           |
| `SB_DFFE`     | pos   | yes    | —               | —           |
| `SB_DFFSR`    | pos   | —      | reset (→0)      | sync        |
| `SB_DFFR`     | pos   | —      | reset (→0)      | async       |
| `SB_DFFSS`    | pos   | —      | set (→1)        | sync        |
| `SB_DFFS`     | pos   | —      | set (→1)        | async       |
| `SB_DFFESR`   | pos   | yes    | reset (→0)      | sync        |
| `SB_DFFER`    | pos   | yes    | reset (→0)      | async       |
| `SB_DFFESS`   | pos   | yes    | set (→1)        | sync        |
| `SB_DFFES`    | pos   | yes    | set (→1)        | async       |
| `SB_DFFN`     | neg   | —      | —               | —           |
| `SB_DFFNE`    | neg   | yes    | —               | —           |
| `SB_DFFNSR`   | neg   | —      | reset (→0)      | sync        |

**Constraints (from Lattice architecture):**
- No variant supports simultaneous set and reset.
- All variants initialize Q=0 on power-up.
- All variants use single-bit Q (each logic cell has exactly one DFF).

---

## SB_RAM40_4K — 4 Kbit True Dual-Port Block RAM

**iCE40 arch cell.** Maps to kernel kind `bram`.

### Physical Location

Each SB_RAM40_4K occupies a RAMB tile + RAMT tile pair. The HX1K has 4 such
pairs (4 block RAMs). The HX8K has 32. The configuration bits for the RAM
are split between the RAMB (bottom) and RAMT (top) tiles.

### Configuration Parameters

| Parameter      | Width | Meaning                                          |
|----------------|-------|--------------------------------------------------|
| `READ_MODE`    | 2     | Read port aspect ratio: 0=256×16, 1=512×8, 2=1024×4, 3=2048×2 |
| `WRITE_MODE`   | 2     | Write port aspect ratio (same encoding)          |
| `INIT_0`..`INIT_F` | 256 each | Initialization data (4 Kbits total, 16 words × 256 bits) |
| `NEGCLK_R`     | 1     | Invert read clock (use negedge RCLK)             |
| `NEGCLK_W`     | 1     | Invert write clock (use negedge WCLK)            |

### Ports

**Write Port:**

| Port       | Dir | Width | Description                       |
|------------|-----|-------|-----------------------------------|
| `WCLK`     | in  | 1     | Write clock (posedge)             |
| `WCLKE`    | in  | 1     | Write clock enable                |
| `WE`       | in  | 1     | Write enable (active high)        |
| `WADDR`    | in  | 11    | Write address (up to 2048 locs)   |
| `WDATA`    | in  | 16    | Write data                        |
| `MASK`     | in  | 16    | Bit write mask (0=write, 1=mask)  |

**Read Port:**

| Port       | Dir | Width | Description                       |
|------------|-----|-------|-----------------------------------|
| `RCLK`     | in  | 1     | Read clock (posedge)              |
| `RCLKE`    | in  | 1     | Read clock enable                 |
| `RE`       | in  | 1     | Read enable (active high)         |
| `RADDR`    | in  | 11    | Read address                      |
| `RDATA`    | out | 16    | Read data output                  |

The effective address and data widths are determined by READ_MODE and
WRITE_MODE. In 256×16 mode (MODE=0), only RADDR[7:0]/WADDR[7:0] and
RDATA[15:0]/WDATA[15:0] are used. In 2048×2 mode (MODE=3), RADDR[10:0]
and RDATA[1:0] are used.

### Clock Variants

| Cell name          | WCLK edge | RCLK edge |
|--------------------|-----------|-----------|
| `SB_RAM40_4K`      | posedge   | posedge   |
| `SB_RAM40_4KNR`    | posedge   | negedge   |
| `SB_RAM40_4KNW`    | negedge   | posedge   |
| `SB_RAM40_4KNRNW`  | negedge   | negedge   |

### Eval Semantics (Cycle-Accurate Model)

```
// Write port (evaluated at WCLK edge)
on rising edge of WCLK (or falling if NEGCLK_W):
    if WCLKE and WE:
        for bit b in 0..(data_width-1):
            if MASK[b] == 0:
                mem[WADDR][b] = WDATA[b]

// Read port (evaluated at RCLK edge)
on rising edge of RCLK (or falling if NEGCLK_R):
    if RCLKE and RE:
        RDATA <= mem[RADDR]
    else:
        RDATA <= RDATA   (hold previous value)
```

The read port is **registered** (synchronous read): RDATA is updated on the
clock edge, not combinationally. This matches the iCE40 block RAM behavior
and the existing `memory` class in the Schem IR (which already models clocked
read/write with `CLK` and `WE`).

### Initialization

`INIT_0` through `INIT_F` each hold 256 bits of initialization data. Together
they describe the full 4 Kbit initial content. The mapping is:
`mem[address][bit] = INIT_<word>[<offset within word>]`. The exact bit packing
follows the IceStorm BRAM documentation; the icebox library handles
extraction from RAM tile config bits.

### Bitstream Encoding (Phase 4)

RAM tile pairs store both the mode configuration bits and the initialization
data in their config arrays. The `icebox_vlog.py` tool extracts INIT_* values
from the `.ram_tile` sections using the icebox BRAM database. The decoder
reads these 16 × 256-bit words and packs them into the BRAM's `init` parameter.

Source: Lattice iCE40 Memory Usage Guide,
https://www.latticesemi.com/-/media/LatticeSemi/Documents/ApplicationNotes/MO/MemoryUsageGuideforiCE40Devices.ashx

---

## SB_IO — Programmable I/O Buffer

**iCE40 arch cell.** Maps to kernel kind `io`.

### Configuration Parameters

| Parameter      | Width | Meaning                                          |
|----------------|-------|--------------------------------------------------|
| `PIN_TYPE`     | 6     | Bits [1:0] = output type; bits [5:2] = input type |
| `PULLUP`       | 1     | Enable internal pull-up resistor                 |
| `NEG_TRIGGER`  | 1     | Invert clock polarity for both registers         |
| `IO_STANDARD`  | string| Voltage standard (e.g., "SB_LVCMOS")            |

### Ports

| Port                  | Dir   | Width | Description                                |
|-----------------------|-------|-------|--------------------------------------------|
| `PACKAGE_PIN`         | inout | 1     | Physical pad connection                    |
| `D_OUT_0`             | in    | 1     | Output data, rising OUTPUT_CLK edge        |
| `D_OUT_1`             | in    | 1     | Output data, falling edge (DDR mode)       |
| `D_IN_0`              | out   | 1     | Input data, sampled rising INPUT_CLK edge  |
| `D_IN_1`              | out   | 1     | Input data, sampled falling edge (DDR)     |
| `OUTPUT_ENABLE`       | in    | 1     | Tri-state control (1 = drive output)       |
| `OUTPUT_CLK`          | in    | 1     | Clock for output register                  |
| `INPUT_CLK`           | in    | 1     | Clock for input register                   |
| `CLOCK_ENABLE`        | in    | 1     | Enables both input and output registers    |
| `LATCH_INPUT_VALUE`   | in    | 1     | Hold input value (glitch filter)           |

### PIN_TYPE Encoding (partial — common modes)

Bits [1:0] (output configuration):
- `2'b00`: output disabled (input only)
- `2'b01`: simple registered output (D_OUT_0 → pin on posedge OUTPUT_CLK)
- `2'b10`: registered with output-enable
- `2'b11`: combinational output (D_OUT_0 directly to pin)

Bits [5:2] (input configuration):
- `4'b0000`: input not registered (D_IN_0 = combinational from pin)
- `4'b0001`: registered input (D_IN_0 latched on posedge INPUT_CLK)
- `4'b0100`: register with latch enable

### Eval Semantics (Simulation)

In fabric simulation, the physical `PACKAGE_PIN` is driven by a stimulus
vector (test bench). The sim model:

```
// Input path
on rising edge of INPUT_CLK (when CLOCK_ENABLE):
    D_IN_0 <= PACKAGE_PIN

// Output path
on rising edge of OUTPUT_CLK (when CLOCK_ENABLE):
    if OUTPUT_ENABLE:
        PACKAGE_PIN <= D_OUT_0
    else:
        PACKAGE_PIN <= Hi-Z
```

DDR modes (D_IN_1, D_OUT_1) use the falling edge. In Phase 3/4 sim,
Hi-Z from the IO is modeled as "not driving" — fabric input pins are
stimulus-driven and output pins are observed values.

### Global Clock Input

An IO pin that drives a global clock network does so through `SB_GB_IO`,
which wraps `SB_IO` and adds `GLOBAL_BUFFER_OUTPUT`. In simulation,
`GLOBAL_BUFFER_OUTPUT` is the same signal as `D_IN_0` (or the pin directly),
and it is treated as a high-priority global net evaluated first each cycle.

Source: IceStorm IO Tile Documentation,
https://prjicestorm.readthedocs.io/en/latest/io_tile.html

---

## SB_GB — Global Buffer

**iCE40 arch cell.** Maps to kernel kind `global_net`.

### Ports

| Port                          | Dir | Width | Description                     |
|-------------------------------|-----|-------|---------------------------------|
| `USER_SIGNAL_TO_GLOBAL_BUFFER`| in  | 1     | Source signal                   |
| `GLOBAL_BUFFER_OUTPUT`        | out | 1     | Global net output (zero-skew)   |

### Eval Semantics

```
assign GLOBAL_BUFFER_OUTPUT = USER_SIGNAL_TO_GLOBAL_BUFFER
```

Functionally a wire. The iCE40 has 8 global networks, used for clocks,
resets, and high-fanout enables. In simulation, global nets are pre-evaluated
at the start of each combinational phase, before any logic cell that uses them,
ensuring all LUTs and DFFs see a consistent clock value.

---

## Kernel Primitive Summary: Eval Rules

This table summarizes the complete eval behavior of each IR primitive kind,
for implementation in the Tcl `digseq`/`fpgaseq` evaluator and the Zig
`-digital` emitter:

| Primitive    | Combinational eval              | Clock-edge eval                      |
|--------------|---------------------------------|--------------------------------------|
| `lut4`       | `O = (init >> idx) & 1`         | (none — purely combinational)        |
| `carry`      | `CO = maj(I0, I1, CI)`          | (none)                               |
| `dff` plain  | Q passes through                | `Q <= D`                             |
| `dff`+enable | Q passes through                | `if E: Q <= D`                       |
| `dff`+srst   | Q passes through                | `if R: Q<=0 else Q<=D`               |
| `dff`+arst   | `if R: Q=0` (override)          | `Q <= D` (R takes over anytime)      |
| `dff`+sset   | Q passes through                | `if S: Q<=1 else Q<=D`               |
| `dff`+aset   | `if S: Q=1` (override)          | `Q <= D` (S takes over anytime)      |
| `dff`+E+srst | Q passes through                | `if E: (if R: Q<=0 else Q<=D)`       |
| `dff`+E+arst | `if R: Q=0`                     | `if ~R and E: Q<=D`                  |
| `dff`+negedge| (same as pos variants)          | trigger on falling clock edge        |
| `bram`       | RDATA holds                     | write on WCLK; read on RCLK          |
| `io`         | comb: D_IN_0 = pin              | D_IN_0 <= pin; pin <= D_OUT_0 if OE  |
| `global_net` | OUT = IN (first in eval order)  | (none)                               |

**Async override rule (for `arst`/`aset`):** In the cycle-accurate boolean
model, async reset/set is modeled as a combinational override evaluated in
the same pass as LUT outputs, before the DFF latch phase. If R=1 at any point
during the cycle, Q is forced to 0 regardless of the clock edge. This matches
the Verilog `always @(posedge C, posedge R)` sensitivity which fires on R's
rising edge independently of C.

---

## Notes on the Phase 3/4 IR Extension

The existing Schem `memory` class in the IR (`src/io/compile.tcl`) already
carries: `abits`/`dbits`, `mode`, data-in/data-out, `WE`, `CLK` nodes.
The BRAM extension adds a second (read) port with independent clock and
address, making it a true dual-port memory. The existing single-port model
covers Phase 3A tests; the dual-port extension is Phase 3B work.

The existing `digseq` evaluator (`src/backend/backend.tcl`) carries relay
and memory state between cycles using a dict of current Q values. The FPGA
extension replaces relays with LUT4 nodes and adds the full DFF variant
matrix; the per-cycle update loop structure is identical.

---

## References

- Yosys iCE40 cells_sim.v: https://github.com/YosysHQ/yosys/blob/main/techlibs/ice40/cells_sim.v
- icebox.py (bit position database): https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox.py
- icebox_vlog.py (prior art decoder): https://github.com/YosysHQ/icestorm/blob/master/icebox/icebox_vlog.py
- Mantle iCE40 primitive docs: https://magma-mantle.readthedocs.io/en/stable/ice40/
- iCE40 Memory Usage Guide: https://www.latticesemi.com/-/media/LatticeSemi/Documents/ApplicationNotes/MO/MemoryUsageGuideforiCE40Devices.ashx
- IceStorm IO Tile Documentation: https://prjicestorm.readthedocs.io/en/latest/io_tile.html
- Project IceStorm main: http://www.clifford.at/icestorm/
