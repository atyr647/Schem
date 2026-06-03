# Schem FPGA — a side project (cycle-accurate software FPGA)

**This is a side project, kept deliberately separate from core Schem.**  Core
Schem is an *electrical* engine — the schematic is the program, solved with MNA
/ Newton / relay logic.  The code here is a different thing: a **cycle-accurate
software FPGA** that imports synthesized digital netlists and runs them, with an
eye toward eventually running existing open FPGA cores (the north star is MiSTer
cores).  It does **not** touch the electrical engine, is **not** loaded by
`bin/schem`, and is **not** part of the main `make test` / CI.  Nothing in
`../src`, `../bin`, `../tests`, `../docs` depends on anything here.

(Note: `../src/backend/digital.tcl` — the relay-logic / `digseq` boolean
evaluator the bombe rides on — *is* core electrical Schem and is unrelated to
this directory despite the shared word "digital".)

## What it does

A real RTL core, synthesized by Yosys to a gate-level netlist, runs three ways
and all three agree cycle-for-cycle:

1. **import** the Yosys `write_json` netlist into a small digital-netlist IR;
2. **interpret** it with a levelized cycle kernel (the generalization of core
   Schem's `digseq`); and/or
3. **compile** it to a native **Zig** cycle simulator;

each verified **bit-identical to Icarus Verilog** on the same design.

## Layout

```
fpga/
  src/digital/   cells.tcl       primitive cells (LUT, gates, compound gates, MUX, DFF family)
                 simkernel.tcl   levelize / settle / tick — the interpreted cycle engine
                 import_yosys.tcl Yosys write_json -> IR
                 zig.tcl         IR -> native Zig cycle simulator
  docs/          DIGITAL.md  FPGA.md  FABRIC.md  FABRIC_PRIMITIVES.md  (MISTER.md)
  experiments/   phase0/  an 8-bit counter (Yosys + Icarus fixtures, gen.sh)
                 phase1/  a 4-bit up/down counter with load+enable
                 phase2/  ram.v — seed for (paused) $mem support
  tests/         run.tcl + test_*.tcl + fixtures/
```

## Running the tests

```sh
tclsh fpga/tests/run.tcl                      # interpreted suites
SCHEM_ZIG=/path/to/zig tclsh fpga/tests/run.tcl   # also the compiled-Zig cross-checks
```

The fixtures under `experiments/` are committed and regenerable with each
phase's `gen.sh` (needs `yosys` + `iverilog`); the tests themselves need only
`tclsh` (and optionally `zig`).

## Status

Working and verified: import + interpret + compile of real synthesized cores
(an 8-bit counter, a 4-bit up/down counter), the full bit-level `$_*_` cell set
+ the DFF family, single clock.  See `docs/` for the design and `docs/MISTER.md`
(when present) for the roadmap toward real cores.  Next bricks: memory (`$mem`),
word-level cells, multi-clock.
