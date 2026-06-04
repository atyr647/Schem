# NES.md -- the bring-up ladder from a 6502 to the MiSTer NES core

The north star of the `fpga/` side project is to run the **MiSTer NES core** on
Schem's software FPGA (the cycle-accurate digital kernel of `docs/DIGITAL.md`,
fed through the Yosys importer of `docs/FPGA.md`). That is a large jump from
where the engine is today (bit-level `$_..._` gates + `$_MUX_` + a single-clock
`$_DFF_P_`, no native memory). This document lays the concrete **rung ladder**:
each rung is a runnable milestone, names the open Verilog to ride, the engine
features it forces, and how to verify it. The first rung is already built:
`../experiments/phase3_6502/` (a verified Arlet 6502).

The honest theme: **the NES is mostly memory and multi-clock.** Each rung mostly
adds *memory* and *clock domains*, not new logic primitives -- so the engine's
critical path is the `$mem` brick and multi-clock support, not exotic cells.

---

## 0. Where the engine is today (the floor)

From `docs/FPGA.md` / `src/digital/cells.tcl`:

- **Implemented cells:** `$_AND_ $_OR_ $_NOT_ $_XOR_ $_XNOR_ $_NAND_ $_NOR_
  $_ANDNOT_ $_ORNOT_`, `$_MUX_` (and `$_NMUX_`/AOI/OAI eval procs exist), and
  the plain rising-edge `$_DFF_P_`. Importer maps these; kernel `settle` runs
  the gates/mux.
- **Specced but STUB:** the sequential loop (`DFF_next`, `tick`/`run`), the rest
  of the flip-flop family (`$_DFFE_*`, `$_SDFF*_`, async `$_DFF_PP?_`), and
  `MEM` (`$mem`/`$mem_v2`). Single clock only. 2-state. No word-level
  (`$add`/`$mux`/`$dff`) cells.

Rung 1 (the 6502 fixture) already proved a real CPU bit-blasts **entirely** into
the implemented cell set (gates+MUX+`$_DFF_P_`); it just needs the sequential
loop turned on. Everything past rung 1 needs `$mem` and (from rung 3) multiple
clocks.

---

## 1. RUNG 1 -- the 6502  (BUILT: `../experiments/phase3_6502/`)

**Why:** the NES CPU is a 6502 (specifically the 2A03 = 6502 core minus decimal
mode, plus APU + DMA). A verified 6502 is the foundation.

- **Source used:** Arlet Ottens' `verilog-6502` (`cpu.v` + `ALU.v`), tiny,
  permissive (attribution-only), plain Verilog. Fully Yosys-synthesizable.
- **Engine features needed:**
  - *Cells:* none new -- bit-blasts to `$_AND_/$_OR_/$_NOT_/$_XOR_/$_XNOR_/
    $_MUX_/$_DFF_P_` (2344 cells, see the fixture's `cpu6502.synth.stat.txt`).
  - *Memory:* the 4x8 register file is a `$mem`; the bit-blast recipe
    (`memory_map`) turns it into 32 flops, so **`$mem` is optional for rung 1**.
    A 2 KB program RAM, if bit-blasted, is ~16 k flops + a 33 k-cell mux
    (`soc.synth.stat.txt`) -- correct but absurd; this *motivates* `$mem`.
  - *Clocks:* single. *SV:* no.
- **Verify:** Icarus per-cycle oracle (`cpu6502.ref.trace`) vs gate-level
  re-sim -- DONE, bit-identical. The engine cross-check is deferred until the
  sequential loop lands.
- **Engine gap to actually run it:** wire `DFF_next` + the
  settle/latch/advance `tick` loop (`docs/DIGITAL.md` section 5). One feature.

---

## 2. RUNG 2 -- the 2A03 (6502 + APU + DMA)

**Why:** the real NES CPU chip. Adds the APU (audio: pulse/triangle/noise/DMC
channels + frame counter) and the OAM-DMA + DMC-DMA engines that steal CPU
cycles. This is the first rung that *must* talk to real RAM.

- **Source to use:** the **fpganes** lineage (Ludvig Strigeus,
  `github.com/strigeus/fpganes`, GPL-2.0, **plain Verilog 98.4%**). Its `src/`
  has `cpu.v`, `apu.v`, `mmu.v`, `dsp.v`, `nes.v`, `ppu.v`, `MicroCode.v`. For
  rung 2 take `cpu.v` + `apu.v` + the DMA logic in `nes.v`/`mmu.v`. (Alternative
  CPU: keep Arlet's from rung 1 and bolt fpganes' `apu.v` on -- both Verilog.)
  Note fpganes' `cpu.v` is its own 6502, *distinct from* the T65 the MiSTer core
  later swaps in (see rung 5).
- **Engine features needed:**
  - *Memory (NEW, REQUIRED):* the 2 KB CPU RAM as a native `$mem` (async or
    sync read). Bit-blasting is off the table now. -> **the `$mem` brick.**
  - *Cells:* APU counters/LFSRs are gates+FFs; the DMC sample fetch is just a
    bus transaction. No new cell *kind*, but lots more `$_DFFE_*`/`$_SDFF*_`
    (counters with enable/reset) -- so the **richer flip-flop family** in the
    importer/kernel is now worth having (the bit-blast-to-`$_DFF_P_` trick still
    works as a fallback but inflates cell count).
  - *Clocks:* still effectively single (APU divides the CPU clock by counters,
    not a separate oscillator) -- stays single-clock if the divider is in logic.
  - *SV:* no (fpganes is Verilog).
- **Verify:** Icarus/Verilator oracle on a CPU+APU testbench running an open
  CPU/APU test ROM (see "Test ROMs"); compare the APU frame-counter IRQ timing
  and a few register reads per cycle, plus RAM writes -- same `cycle <n>
  <sig>=<val>` text-oracle pattern as the phase fixtures.

---

## 3. RUNG 3 -- the PPU (background + sprite render to a framebuffer)

**Why:** the Picture Processing Unit is the NES's defining part and the first
**multi-memory, multi-clock** rung. It renders a 256x240 frame from pattern
tables, name tables, attribute tables and sprites.

- **Source to use:** fpganes `ppu.v` (plain Verilog), or NESTang's PPU
  (`github.com/nand2mario/nestang`, also portable plain Verilog, see rung 4).
- **Engine features needed:**
  - *Memory (REQUIRED, several):* 2 KB VRAM/name-table RAM, 256 B **OAM** (+ 32 B
    secondary OAM), 32 B palette RAM, and read access to CHR ROM/RAM (pattern
    tables, up to MBs). All native `$mem`. The OAM evaluation reads OAM every
    scanline -- needs a real async-read port.
  - *Clocks (NEW):* the PPU runs at ~3x the CPU clock (the NES master clock is
    divided by 12 for CPU, by 4 for PPU). Faithful timing wants **two clock
    domains** (CPU and PPU) with the CPU/PPU bus crossing. The engine's
    multi-clock extension (`docs/DIGITAL.md` section 5, "Multi-clock") becomes
    necessary here -- OR drive a single master clock and divide in logic (less
    faithful but single-clock; acceptable for a first bring-up).
  - *Cells:* shift registers, multiplexers, comparators for sprite-0 / sprite
    overlap -- all within the gate+FF+mux set; comparators bit-blast.
  - *SV:* fpganes PPU is Verilog; MiSTer's `ppu.sv` is SystemVerilog (rung 5).
- **Verify:** render one full frame to a framebuffer (a `$mem` or a dumped
  array) and **framebuffer-compare** against an Icarus/Verilator run of the same
  PPU + a known pattern. The oracle is the reference sim's framebuffer dump
  (PPM/raw bytes); the engine's framebuffer must match pixel-for-pixel. This is
  the first rung where the "trace" is a frame, not a per-cycle scalar.

---

## 4. RUNG 4 -- the full NES (CPU+PPU+APU+mapper+RAM/ROM, boot a .nes, dump a frame)

**Why:** the whole console, booting a real (open) ROM image and producing a
frame -- the proof that the software FPGA runs a system, not a part.

- **Source to use:** ride a **complete, plain-Verilog, portable** NES.
  Recommendation: **NESTang** (`nand2mario/nestang`) -- it is plain Verilog,
  explicitly *portable* across boards (less board-locked than fpganes' Xilinx
  ISE / Nexys4 build), has CPU/PPU/APU + an extensive mapper set, and is
  actively maintained. fpganes is the historical ancestor and also viable, but
  is wired to Xilinx ISE primitives and a Nexys4 top. For maximum Yosys-
  friendliness use the NESTang core RTL with the board top + Gowin/Sipeed-
  specific bits (SDRAM controller, PLL, RISC-V loader) **stubbed**.
- **Engine features needed:**
  - *Memory (the big one):* CPU RAM 2 KB, VRAM 2 KB, OAM 256 B, palette 32 B,
    **PRG-ROM** and **CHR-ROM** (cartridge, up to multiple MB) -- the ROMs MUST
    be native `$mem` with init contents from the `.nes` file. A megabyte of ROM
    bit-blasted is millions of flops; native `$mem` is mandatory. Mapper bank
    registers select which ROM window is visible (address math + a `$mem` read).
  - *Clocks:* CPU + PPU domains as in rung 3; APU shares CPU.
  - *Cells:* mapper logic is gates+FFs+comparators; nothing new.
  - *SV:* depends on the chosen core (NESTang Verilog vs MiSTer SV); plain
    Verilog keeps `read_verilog` happy without `-sv`.
  - *Loader:* the `.nes` (iNES) header + PRG/CHR split must be parsed by a small
    host-side loader that fills the `$mem` init arrays (the software analogue of
    NESTang's RISC-V ROM loader / MiSTer's hps_io file load).
- **Verify:** boot an **open** test ROM, run a fixed number of frames, dump a
  frame, and compare against an Icarus/Verilator reference of the same core +
  same ROM. Framebuffer compare + (optionally) a CPU PC/RAM trace for the first
  N cycles.

---

## 5. RUNG 5 -- the MiSTer NES core (add the framework wrapper)

**Why:** the actual north star. The MiSTer core is fpganes' descendant,
heavily reworked.

- **What it is:** `github.com/MiSTer-devel/NES_MiSTer`, **rtl/** is ~54%
  **SystemVerilog** + ~21% **VHDL** + ~22% Verilog. Core RTL: `nes.v`
  (Verilog), `ppu.sv` / `apu.sv` / `cart.sv` (SystemVerilog), `mappers/`
  (SV), and -- importantly -- the **CPU is the VHDL `T65`** core, *not* fpganes'
  Verilog `cpu.v` (the MiSTer port swapped it). DMA is `DmaController`.
- **Engine / toolchain features needed:**
  - *Mixed-language front end:* SystemVerilog (`read_verilog -sv`, mostly fine
    in Yosys 0.33) **and VHDL** -- the T65 CPU and the `*.vhd` save-state /
    dual-port-RAM (`dpram.vhd`) files need the **Yosys GHDL plugin** (or replace
    T65 with a Verilog 6502 -- e.g. Arlet's from rung 1 -- to stay pure-Verilog).
    This is the single biggest front-end lift.
  - *All of rung 4's memory + multi-clock*, plus save-state state machines.
  - *Framework pieces that MUST be STUBBED* (Intel/Altera-specific, not real
    logic to simulate): the `sys/` MiSTer framework, **SDRAM controller**
    (`sdram.sv`/`ddram.sv`, holds PRG/CHR -- replace with a behavioral `$mem`),
    **`hps_io`** (ARM-side I/O: file loading, OSD, controls -- replace with a
    host loader + tied-off inputs), **PLL** (`pll.v`/`pll.qip`, an Intel
    `altpll` megafunction -- replace with the engine's clock(s)), the **video
    pipeline / scaler** (HDMI/scandoubler in `sys/` -- replace with a raw
    framebuffer dump), and any Intel primitives (`altsyncram` block RAM, DSP).
    These are the boundary between "the NES" (simulate) and "the MiSTer board"
    (stub).
- **Verify:** same framebuffer compare against a Verilator build of the MiSTer
  core (Verilator handles SV; VHDL via GHDL or a Verilog CPU swap), booting the
  same open ROM. Match the dumped frame.

---

## Best open NES Verilog lineage to ride

| Project | Language | Portability / toolchain | Closeness to MiSTer | Recommendation |
|---|---|---|---|---|
| **fpganes** (Strigeus) | plain Verilog (98%) | Xilinx ISE, Nexys4-locked top, GPL-2.0 | **the ancestor** of the MiSTer core | best for **rungs 2-3** (Verilog CPU/APU/PPU, no SV/VHDL needed) |
| **NESTang** (nand2mario / Sipeed) | plain Verilog | explicitly **portable** across boards, active | a parallel descendant, not the MiSTer line | best for **rung 4** (a complete, Yosys-friendly, portable full NES) |
| **NES_MiSTer** | ~54% **SV** + 21% **VHDL** + Verilog | Intel Quartus, MiSTer `sys/` framework | **the target itself** | **rung 5** -- needs `-sv` + GHDL (or swap T65 for a Verilog 6502) |

**Strategy:** bring up the system on plain-Verilog cores (fpganes / NESTang)
where Yosys needs no SV/VHDL plugins, prove the engine runs a full NES, *then*
tackle the MiSTer core's SystemVerilog + VHDL (T65) front-end and stub its Intel
framework. The MiSTer core adds, on top of the NES logic: SDRAM for PRG/CHR,
`hps_io` for file/OSD/controls, an `altpll` PLL, a video scaler, save-states,
and Intel block-RAM/DSP primitives -- all of which a software sim **stubs**
(behavioral `$mem` for SDRAM/BRAM, a host loader for hps_io, engine clocks for
the PLL, a raw framebuffer for the scaler).

---

## Memory reality for the NES (why the engine needs a `$mem` brick)

This is the crux. Enumerate every NES memory and whether it can bit-blast to
flip-flops or **must** be a native `$mem` array:

| Memory | Size | Read | Bit-blast OK? | Must be native `$mem`? |
|---|---|---|---|---|
| CPU work RAM | 2 KB | async | ~16 k flops + huge mux -- no | **yes** |
| PPU VRAM / name tables | 2 KB | async | same -- no | **yes** |
| OAM (sprite) | 256 B | async | ~2 k flops -- borderline | **yes** (per-scanline reads) |
| Secondary OAM | 32 B | async | ~256 flops -- *could* blast | preferably `$mem` |
| Palette RAM | 32 B | async | ~256 flops -- *could* blast | preferably `$mem` |
| CPU register file (in the 6502) | 4-32 B | sync | trivially blasts (rung 1 did) | optional |
| **PRG-ROM** (cartridge) | 16 KB - **MBs** | async | **impossible** (millions of flops) | **yes** (init from `.nes`) |
| **CHR-ROM/RAM** (cartridge) | 8 KB - **MBs** | async | **impossible** | **yes** (init from `.nes`) |
| Framebuffer (sim artifact) | 256x240 | -- | -- | `$mem` (output sink) |

Takeaway: the tiny register file proved bit-blasting *works* (rung 1), but the
2 KB RAMs are already a ~16 k-flop / 33 k-mux blow-up (measured:
`../experiments/phase3_6502/soc.synth.stat.txt`), and the MB-scale cartridge
ROMs are flat-out impossible to bit-blast. **A native `$mem`/`$mem_v2` brick
(the `MEM` stub in `cells.tcl`) is the single hard dependency for every rung
past the bare 6502.** It must support: ROM init from a host-loaded file
(PRG/CHR), async read (CPU/PPU buses), sync read (some block RAMs), and
edge-triggered writes (RAM).

---

## Licensing -- ROMs (be strict)

Use only **open** homebrew / test ROMs. Never a copyrighted commercial game ROM.

- **`christopherpow/nes-test-roms`** -- the standard collection used to validate
  emulators/cores (CPU, PPU, APU, mapper tests). Includes Blargg's suites; the
  audio tests (`bbbradsmith/nes-audio-tests`, Blargg) state they may be freely
  redistributed and modified. Check each ROM's own license note before
  committing it; prefer the explicitly free ones.
- For a "boots and renders" demo, use a known **homebrew** `.nes` released under
  a free license (CC0 / public-domain / permissive) -- verify the license per
  ROM. Do **not** vendor `nestest` blindly without confirming its terms; many
  test ROMs are freely redistributable but say so individually.
- Keep ROM provenance + license recorded next to any committed `.nes`, exactly
  as `../experiments/phase3_6502/` records the Arlet CPU's provenance.

---

## Summary -- the critical path

1. **Sequential loop** (`DFF_next` + `tick`/`run`): unlocks **rung 1** (the
   built 6502 fixture) -- no new cells.
2. **Native `$mem` brick** (ROM init + async/sync read + write): the hard gate
   for **rungs 2-5**; without it RAM blows up and ROM is impossible.
3. **Multi-clock + the richer flip-flop family** (`$_DFFE_*`/`$_SDFF*_`):
   needed for faithful **PPU/CPU** timing (rung 3+) and compact import of real
   cores; the single-clock + bit-blast-to-`$_DFF_P_` fallback works first.
4. **SystemVerilog + VHDL front end** (Yosys `-sv` + GHDL plugin, or swap T65
   for a Verilog 6502): only for **rung 5**, the MiSTer core itself.

Sources: MiSTer-devel/NES_MiSTer, strigeus/fpganes, nand2mario/nestang,
christopherpow/nes-test-roms, bbbradsmith/nes-audio-tests, OpenCores T65.
