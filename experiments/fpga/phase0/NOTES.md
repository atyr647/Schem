# Phase 0 SPIKE — Open FPGA Toolchain Feasibility + Ground-Truth Fixtures

Date: 2026-06-03
Environment: Ubuntu 24.04.4 LTS (Noble), running as root, apt-get + GitHub network reachable.

This document records what was obtained, what is **real tool output** vs **hand-authored**,
the Yosys JSON schema reference, the reference-trace format, and a viability recommendation.

---

## 1. Tools obtained

All three target tools installed cleanly from the **Ubuntu archive via `apt-get`** — no
prebuilt tarball or source build was needed, and nothing failed.

| Tool           | Version (exact)                                    | Source                       | Status |
|----------------|----------------------------------------------------|------------------------------|--------|
| Yosys          | `Yosys 0.33 (git sha1 2584903a060)`                | `apt-get install yosys` (0.33-5build2) | OK |
| Verilator      | `Verilator 5.020 2024-01-01 rev (Debian 5.020-1)`  | `apt-get install verilator`  | OK (installed; not used to generate fixtures — Icarus was sufficient) |
| Icarus Verilog | `Icarus Verilog version 12.0 (stable)` (`iverilog`/`vvp`) | `apt-get install iverilog` | OK — used as the reference simulator |

Install command that worked:
```
apt-get update
apt-get install -y yosys verilator iverilog
```

Nothing was skipped or abandoned. The oss-cad-suite tarball fallback was **not needed**.
GitHub was reachable (`curl -sSI https://github.com` -> HTTP/2 200) but unused.

> **EVERYTHING in this directory is real tool output.** No fixture in Phase 0 was
> hand-authored. (Deliverable item 5 — hand-authoring — was the fallback path for the
> case where Yosys could not be installed; that case did not occur, so it was not taken.)

---

## 2. Designs (RTL source, written for this spike)

- `counter.v` — 8-bit synchronous up-counter. `clk`, **synchronous** active-high `rst`,
  `output reg [7:0] q`. Wraps 255 -> 0. A synchronous reset was chosen deliberately:
  it synthesizes to a clean bank of `$_SDFF_PP0_` flops + an adder, which is the simplest
  shape for a cycle-accurate interpreter to consume.
- `blinky.v` — parameterized clock divider, `parameter WIDTH=4, DIVISOR=10`, toggling
  `output reg led` each time the internal counter reaches `DIVISOR-1`. Synchronous reset.

These are synthesizable; both pass `read_verilog` + `synth` with no warnings about
non-synthesizable constructs.

---

## 3. Synthesized netlists (real Yosys 0.33 output)

Two flows per design were run and saved:

| File                  | Flow                                                       | Description |
|-----------------------|------------------------------------------------------------|-------------|
| `counter.synth.json`  | `read_verilog; proc; opt; techmap; opt; write_json`        | GENERIC gate-level (mapped to `$_*_` primitive cells) |
| `counter.coarse.json` | `read_verilog; synth; write_json`                          | Coarser full `synth` run |
| `blinky.synth.json`   | `read_verilog; proc; opt; techmap; opt; write_json`        | GENERIC gate-level |
| `blinky.coarse.json`  | `read_verilog; synth; write_json`                          | Coarser full `synth` run |

(NB: `counter.v` was passed only via `read_verilog` inside the `-p` script, *not* also as
a positional argument, to avoid Yosys reading the file twice and creating a stray
`$abstract\counter` module.)

Observed cell-type inventories:

- `counter.synth.json` (24 cells): `$_SDFF_PP0_`×8, `$_AND_`×8, `$_XOR_`×7, `$_NOT_`×1
- `counter.coarse.json` (24 cells): `$_SDFF_PP0_`×8, `$_XOR_`×4, `$_NAND_`×3, `$_XNOR_`×3,
  `$_ANDNOT_`×3, `$_OR_`×2, `$_NOT_`×1
- `blinky.synth.json` (18 cells): `$_SDFF_PP0_`×4, `$_SDFFE_PP0N_`×1, `$_NOT_`×4,
  `$_OR_`×4, `$_XOR_`×3, `$_AND_`×2

`$_SDFF_PP0_` = D flip-flop, **P**ositive clock edge, **P**ositive-polarity sync reset,
reset value **0**. `$_SDFFE_*` adds a clock-enable. These bit-level `$_*_` cells (note the
leading-and-trailing underscores) are exactly the primitive set a cycle-accurate evaluator
should support first.

> Note: the spike used a generic/coarse flow rather than an architecture-specific one
> (`synth_ice40`, `synth_ecp5`, ...). Generic `$_*_` primitives are
> architecture-independent and the right target for a first software-FPGA evaluator. A
> real "run an existing open FPGA core" goal will later need an architecture pass to get
> LUTs/BRAMs, but that is out of Phase 0 scope.

### Self-consistency cross-check (extra confidence)

`counter.synth.json` was also emitted as Verilog (`write_verilog -noattr` ->
`counter.synth.v`) and re-simulated with the same testbench. Its per-cycle trace
(`counter.gl.trace`) is **bit-identical** to the RTL trace `counter.ref.trace`
(`diff` clean). So the synthesized netlist provably implements the same behavior as the
RTL oracle. `counter.synth.v` and `counter.gl.trace` are kept as evidence.

---

## 4. Yosys JSON schema — concise field reference

Top level:
```json
{
  "creator": "Yosys 0.33 (...)",
  "modules": { "<module_name>": { ... } }
}
```

Each module object:
```json
{
  "attributes": { "...": "..." },          // module-level attrs (top, src, ...)
  "ports":     { "<portname>": <PORT> },   // the module boundary
  "cells":     { "<cellname>": <CELL> },   // the gates / flops
  "netnames":  { "<wirename>": <NET> }     // named wires (for readability/debug)
}
```

**Bits / nets.** A "bit" is an integer net id (a node in the graph). Multi-bit signals are
arrays of these ints, LSB first. The special string constants `"0"`, `"1"`, `"x"`, `"z"`
appear in bit arrays to denote constant-driven bits. Net id integers `0` and `1` are *not*
used as constants — constants are the strings.

`<PORT>`:
```json
{ "direction": "input" | "output" | "inout",
  "bits": [ <net_id>, ... ] }            // LSB first; e.g. q -> [4,5,6,7,8,9,10,11]
```

`<CELL>`:
```json
{
  "hide_name": 0 | 1,                    // 1 = autogenerated ($auto$...) name
  "type": "$_SDFF_PP0_",                 // primitive ($_*_), coarse ($add,$mux...), or module
  "parameters":      { "WIDTH": "...", ... },   // e.g. $add carries A_WIDTH/Y_WIDTH; $_*_ usually {}
  "attributes":      { "src": "counter.v:17.5-22.8" },
  "port_directions": { "C": "input", "D": "input", "Q": "output", "R": "input" },
  "connections":     { "C": [2], "D": [12], "Q": [4], "R": [3] }   // port -> bit array
}
```
`connections` is the actual wiring: each cell port maps to an array of net ids; you build
the netlist graph by joining cells that share a net id.

`<NET>` (netnames entry):
```json
{ "hide_name": 0 | 1,
  "bits": [ <net_id>, ... ],
  "attributes": { "src": "counter.v:15.23-15.24" } }
```
`netnames` is informational (human-readable wire labels); the graph is fully defined by
ports + cells alone.

Verbatim excerpts from the **real** `counter.synth.json`:

```json
// ports
"q": { "direction": "output", "bits": [4,5,6,7,8,9,10,11] },
"clk": { "direction": "input", "bits": [2] },
"rst": { "direction": "input", "bits": [3] }

// a D flip-flop cell (sync reset, reset-to-0, posedge clk)
"$auto$ff.cc:266:slice$85": {
  "hide_name": 1, "type": "$_SDFF_PP0_", "parameters": {},
  "port_directions": { "C":"input","D":"input","Q":"output","R":"input" },
  "connections":     { "C":[2], "D":[12], "Q":[4], "R":[3] }
}

// an XOR (bit of the increment)
"$auto$simplemap.cc:75:simplemap_bitop$102": {
  "hide_name": 1, "type": "$_XOR_", "parameters": {},
  "port_directions": { "A":"input","B":"input","Y":"output" },
  "connections":     { "A":[5], "B":[4], "Y":[13] }
}

// a named wire
"q": { "hide_name": 0, "bits": [4,5,6,7,8,9,10,11],
       "attributes": { "src": "counter.v:15.23-15.24" } }
```

Common primitive cell port conventions (for the evaluator):
- Combinational 2-input: ports `A`, `B` (inputs), `Y` (output) — `$_AND_ $_OR_ $_XOR_ $_NAND_ $_NOR_ $_XNOR_ $_ANDNOT_ $_ORNOT_`.
- Inverter `$_NOT_`: `A` in, `Y` out.
- Mux `$_MUX_`: `A`, `B`, `S` in, `Y` out (Y = S ? B : A).
- DFF `$_DFF_P_`: `C` (clk) in, `D` in, `Q` out.
- Sync-reset DFF `$_SDFF_PP0_`: `C`,`D`,`R` in, `Q` out (R active-high, resets to 0).
- Enabled variants add `E` (clock enable), e.g. `$_SDFFE_PP0N_` (E active-low here).

The 3rd/4th letters in `$_SDFF_xy0_` encode clock edge polarity / reset polarity; the
trailing `0` (or `1`) is the reset value.

---

## 5. Reference trace format (the downstream oracle)

File: `counter.ref.trace` — produced by Icarus Verilog (`vvp`) simulating **`counter.v`**
(the RTL) via `counter_tb.v`. **Real tool output.**

Format — one line per counted rising edge, nothing else in the file:
```
cycle <n> q=<value>
```
- `<n>`: decimal cycle index, starting at 0, monotonically increasing.
- `<value>`: decimal value of `q` sampled **after** that rising edge.
- Exactly 40 lines (`cycle 0` .. `cycle 39`). No header, no trailing simulator chatter
  (the `VCD info:` and `$finish` lines emitted by `vvp` are filtered out with
  `grep -E '^cycle [0-9]+ q=[0-9]+$'` so the file is pure oracle data).

Cycle convention (so a re-implementation can reproduce byte-identical lines):
- One reset rising edge happens first and is **not** printed (`rst=1` -> `q<=0`).
- `rst` is released, then 40 free-running edges are counted.
- The counter was at 0 after reset, so the first counted edge yields `q=1`. Hence
  `cycle n` has `q == (n+1) & 0xFF`. First/last lines:
  ```
  cycle 0 q=1
  cycle 1 q=2
  ...
  cycle 39 q=40
  ```
A downstream cycle-accurate model should diff its emitted lines against this file verbatim.

Also produced: `counter.ref.vcd` — full VCD waveform of the same run (real `$dumpvars`
output), for waveform-level inspection / GTKWave.

---

## 6. File inventory (all under `experiments/fpga/phase0/`)

| File                  | Real / hand-authored | What it is |
|-----------------------|----------------------|------------|
| `counter.v`           | source (written for spike) | 8-bit sync up-counter RTL |
| `blinky.v`            | source (written for spike) | parameterized clock divider RTL |
| `counter_tb.v`        | source (written for spike) | Icarus testbench / oracle generator |
| `counter.synth.json`  | **REAL** Yosys output | generic gate-level netlist |
| `counter.coarse.json` | **REAL** Yosys output | `synth` flow netlist |
| `blinky.synth.json`   | **REAL** Yosys output | generic gate-level netlist |
| `blinky.coarse.json`  | **REAL** Yosys output | `synth` flow netlist |
| `counter.synth.v`     | **REAL** Yosys output | netlist re-emitted as Verilog (cross-check) |
| `counter.ref.trace`   | **REAL** Icarus output | per-cycle oracle (40 lines) |
| `counter.gl.trace`    | **REAL** Icarus output | gate-level re-sim trace, == counter.ref.trace |
| `counter.ref.vcd`     | **REAL** Icarus output | VCD waveform |

No file in this directory is hand-authored fixture data.

---

## 7. Viability recommendation

**The real open toolchain is fully viable in this environment.** Yosys 0.33, Verilator
5.020, and Icarus Verilog 12.0 all install in well under a minute from the Ubuntu archive
with network access, and produce correct, self-consistent artifacts (the synthesized
netlist re-simulates bit-identically to the RTL oracle).

Recommendation for downstream Phase 1+ work:
1. **Rely on real tool output, not hand-authored fixtures.** Regenerate fixtures from a
   committed script so they are reproducible. (A `gen.sh` was intentionally not added in
   Phase 0 to honor the "only create the requested files" scope, but the exact commands
   are recorded in sections 3 and 5 above and are trivially scriptable.)
2. **Target the generic `$_*_` primitive cell set first** (`$_DFF_P_`, `$_SDFF_*_`,
   `$_AND_/$_OR_/$_XOR_/$_NOT_/$_MUX_`, enabled-DFF variants). The Yosys JSON in section 4
   is a complete-enough graph: ports + cells + connections.
3. **Use the `cycle <n> q=<value>` text trace as the primary diff oracle**, with the VCD as
   a secondary human-inspection artifact.
4. Pin tool versions (Yosys 0.33, Icarus 12.0) in CI; if the runner lacks network, cache
   the apt packages or the oss-cad-suite tarball. The hand-authored fallback (deliverable
   item 5) is **not needed here** but remains the documented contingency for an offline
   runner.
5. For the eventual "run existing open FPGA cores" goal, add an architecture synthesis pass
   (e.g. `synth_ice40 -json`) — out of Phase 0 scope but a natural next step.
