# Phase 3 -- a verified 6502 CPU fixture

The first concrete rung toward running the MiSTer NES core: the NES CPU is a
6502 (a 2A03, = 6502 core + APU + DMA), so a verified 6502 is the foundation.
This directory is a self-contained, deterministic 6502 fixture in the exact
shape of `../phase0` / `../phase1`: real RTL -> Yosys synthesis -> Icarus
per-cycle oracle -> bit-identical gate-level cross-check.

There is **no Tcl test** here. The engine (`../../src/digital/`) cannot run this
yet -- see "What the engine still needs" below. This is a fixture + research
deliverable only.

## 1. The CPU: Arlet Ottens' verilog-6502

- **Source:** `cpu.v` + `ALU.v`, fetched **verbatim** from
  `https://github.com/Arlet/verilog-6502` (raw `master`), on 2026-06-04.
  `cpu.v` is the 6502 core (instruction decoder + microcode state machine +
  register file + PC/SP logic); `ALU.v` is the arithmetic/logic unit it
  instantiates.
- **License / provenance:** there is no separate `LICENSE` file in the upstream
  repo; the license is the per-file header, reproduced verbatim at the top of
  `cpu.v` and `ALU.v`:

  > (C) Arlet Ottens, <arlet@c-scape.nl>
  > Feel free to use this code in any project (commercial or not), as long as you
  > keep this message, and the copyright notice. This code is provided "as is",
  > without any warranties of any kind.

  This is a permissive, attribution-only grant (BSD/Zlib-spirited). The headers
  are kept intact. This is the widely-used, tiny, permissive 6502 the task
  recommended; no clean-room fallback was needed.
- **Interface** (`module cpu`): `clk`, `reset` (active high), `AB[15:0]`
  (address bus, out), `DI[7:0]` (data in / read bus), `DO[7:0]` (data out /
  write bus), `WE` (write enable), `IRQ`, `NMI`, `RDY` (tied to 1 here).
  Read/write are separate buses (combine externally if needed). On reset the
  core runs its BRK sequence and fetches the reset vector from `$FFFC/$FFFD`.

`cpu.v` / `ALU.v` are the ONLY non-authored files; everything else
(`soc.v`, `soc_tb.v`, `gen.sh`) is written for this fixture, and every `*.json`
/ `*.trace` / `*.stat.txt` / `*.vcd` is **real tool output** from `gen.sh`.

## 2. The harness and the test program

`soc.v` is the synthesis top: the `cpu` core wrapped around a **2 KB synchronous
RAM**, addressed by the low 11 bits of `AB`. The CPU reset vector at
`$FFFC/$FFFD` is overlaid to return `$0200`, so execution starts at `$0200`
where the program is loaded. The RAM is registered: on each rising clock it
latches the read byte into `DI` and, when `WE`, writes `DO` to `RAM[AB]`.

The program (hand-assembled into `mem[]` in `soc.v`) exercises an immediate
load, a zero-page store, the X index register, the ALU (increment + compare +
indexed-address add), a taken/not-taken **branch**, and **memory writes**:

```
        ; reset vector ($FFFC/$FFFD) -> $0200
0200  A2 00     LDX #$00       ; X = 0
0202  A9 42     LDA #$42       ; A = 0x42
0204  85 10     STA $10        ; RAM[$0010] = $42         (memory write)
0206  E8        INX            ; X = X + 1                (ALU increment)
0207  8A        TXA            ; A = X
0208  95 20     STA $20,X      ; RAM[$0020+X] = A         (indexed write + ALU add)
020A  E0 05     CPX #$05       ; compare X with 5         (ALU subtract / flags)
020C  D0 F8     BNE $0206      ; loop back while X != 5   (branch)
020E  4C 0E 02  JMP $020E      ; spin forever
```

It writes `$42` to `$0010` once, then loops X = 1..5 storing X into
`$0021..$0025`; the last store before the loop exits (at X=5, which falls
through the BNE) leaves `RAM[$0024] = $04`. The fixture observes both.

### Trace format

`soc_tb.v` prints one line per post-reset rising clock edge to
`cpu6502.ref.trace` (and dumps `soc.ref.vcd`):

```
cycle <n> AB=<hhhh> DB=<hh> WE=<b> DI=<hh> R10=<hh> R24=<hh>
```

- `AB`   = CPU address bus (4 hex)
- `DB`   = CPU write-data `DO` (2 hex)
- `WE`   = write enable (0/1)
- `DI`   = byte presented to the CPU this cycle (2 hex)
- `R10`  = `RAM[$0010]` (the `STA $10` target)
- `R24`  = `RAM[$0024]` (the last indexed-store target)

220 cycles are traced -- enough to see reset, the linear prologue, all five loop
iterations, and the final `JMP` spin. The first ~3 cycles legitimately show `xx`
on `DB`/`DI` (the core's data path before the first real fetch); these `x`
values are produced identically by RTL and gate-level (both 4-state Icarus
sims), so the cross-check is still bit-exact. Landmarks: `R10` becomes `42` at
cycle 11; `R24` becomes `04` at cycle 58; the `JMP` spin (AB cycling
`020E/020F/0210`) begins at cycle 76.

## 3. Synthesis flows and the CELL INVENTORY

`gen.sh` runs three Yosys flows (all from `cpu.v`/`ALU.v`, plus `soc.v` for the
third). Cell counts are real `stat` output, saved alongside.

### (a) Coarse -- `cpu6502.coarse.json` (`cpu6502.coarse.stat.txt`)

`proc; opt; techmap; opt` of the CPU core. **2122 cells + 1 memory (32 bits).**
This is what a naive flow leaves, and it is NOT yet within the engine's cell set:

- The 4x8 **register file** stays as `$memrd` + `$memwr_v2` (a `$mem`). The
  engine has **no** `$mem`/`$mem_v2` support yet (it is the documented `MEM`
  primitive in `cells.tcl`, but a stub).
- The flip-flops come out as the **rich family**: `$_DFFE_PP_` (82, enable),
  `$_DFFE_PP0P_/PP1P_` (async-reset+enable), `$_SDFFE_*` / `$_SDFFCE_*`
  (sync-reset, some negedge-enable). The engine's importer today maps only the
  plain `$_DFF_P_` ("done"); the rest are TODO (see `../../docs/FPGA.md`).

### (b) Bit-blasted CPU -- `cpu6502.synth.json` (`cpu6502.synth.stat.txt`)

The recipe that lowers the CPU **entirely into the engine's current cell set**:

```
flatten; proc; opt; memory_map; opt; techmap; opt; async2sync; opt;
dfflegalize -cell $_DFF_P_ 0 -mince 999999 -minsrst 999999; opt_clean
```

- `memory_map` bit-blasts the 4x8 regfile into flip-flops + read muxes (no
  more `$mem`).
- `async2sync` rewrites the async reset as synchronous logic.
- `dfflegalize ... -mince 999999 -minsrst 999999` **unmaps every clock-enable
  and sync-reset into soft `$_MUX_` logic**, leaving only plain `$_DFF_P_`.
- `opt_dff` is deliberately NOT run afterward (it would re-infer the enables/
  resets we just unmapped and undo the lowering).

Result -- **2344 cells, 0 memories**, and the inventory is exactly:

| Yosys cell | count | engine support |
|------------|------:|----------------|
| `$_OR_`    | 1070  | done (`Gate_eval` OR) |
| `$_MUX_`   |  414  | done (`MUX_eval`) |
| `$_AND_`   |  436  | done (`Gate_eval` AND) |
| `$_NOT_`   |  213  | done (`Gate_eval` NOT) |
| `$_DFF_P_` |  143  | done (importer + `DFF` cell, but kernel latch is a STUB) |
| `$_XOR_`   |   67  | done (`Gate_eval` XOR) |
| `$_XNOR_`  |    1  | done (`Gate_eval` XNOR) |

**Every cell type is within the engine's current cell set** (the `$_..._` gates
+ `$_MUX_` + `$_DFF_P_`, all marked "done" in `docs/FPGA.md` and implemented in
`src/digital/cells.tcl`). No word-level `$add`/`$mux`/`$dff`, no `$mem`, no AOI/
OAI/compound or latch cells appear. So the **6502, with its register file
bit-blasted, needs no new CELL TYPE** -- only the kernel's sequential loop wired
up (see below).

### (c) Whole SoC, RAM bit-blasted -- `soc.synth.stat.txt`

The same recipe on `soc.v` (CPU + 2 KB RAM). `memory_map` bit-blasts the RAM
too: **55,743 cells -- 16,525 `$_DFF_P_` + 33,135 `$_MUX_`** (plus gates). This
is the honest demonstration that *small memories bit-blast to DFFs + a giant
read mux*: a 2 KB RAM alone is ~16 k flops and a ~33 k-cell address mux. It is
correct but absurdly expensive -- which is exactly why the engine needs a native
`$mem` brick rather than blasting ROM/RAM. (The 30 MB JSON is not committed;
only the stat is.)

## 4. Cross-check (the phase0 pattern)

`gen.sh` re-emits the bit-blasted CPU as Verilog (`cpu6502.synth.v`, module
`cpu`), drops it into the SAME `soc.v` harness + `soc_tb.v`, re-simulates in
Icarus, and diffs against the RTL oracle:

```
diff cpu6502.ref.trace cpu6502.gl.trace   ->   IDENTICAL (220/220 lines)
```

`gen.sh` exits non-zero on any mismatch. **Result: PASS** -- the synthesized
netlist is bit-identical to the RTL, so the inventory above faithfully
represents the same 6502.

## 5. What the engine still needs to actually RUN this

The netlist is within the cell *set*, but the kernel cannot execute it yet:

1. **The sequential cycle loop.** `cells.tcl`'s `DFF_next` and the
   `settle`/`tick`/`run` loop in `simkernel.tcl` are documented STUBS. Wiring
   the "settle the comb cone, latch `$_DFF_P_` on the rising edge, advance"
   loop (per `docs/DIGITAL.md` section 5) is the one thing needed to run the
   **bit-blasted CPU** fixture (b) -- no new cell type required.
2. **A native `$mem` / `$mem_v2` brick.** Bit-blasting even a 2 KB RAM is 16 k
   flops; real NES PRG/CHR ROM is up to MBs. The engine needs `MEM` (also a
   `cells.tcl` stub) wired into settle/tick so the regfile (coarse flow) and any
   real RAM/ROM stay as array state, not flops. This is what lets the SoC
   (CPU+RAM) run without the 55 k-cell blow-up.
3. **The richer flip-flop family in the importer/kernel** (`$_DFFE_*`,
   `$_SDFF*_`, `$_DFF_PP?_` async). The bit-blast recipe avoids these by
   unmapping them into muxes, but a faithful, compact import of real cores
   (and most NES RTL) wants them mapped directly -- they are specced in
   `cells.tcl` (DFFE/SDFF/ADFF) but TODO in the importer.

## 6. Reproduce

```
./gen.sh    # needs yosys 0.33, iverilog/vvp 12.0 (see ../phase0/NOTES.md)
```

Deterministic: the JSONs, traces, and stat files reproduce byte-for-byte.
