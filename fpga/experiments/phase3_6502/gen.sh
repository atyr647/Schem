#!/usr/bin/env bash
# gen.sh -- regenerate the Phase 3 (6502) ground-truth fixtures from the RTL.
#
# Mirrors ../phase0/gen.sh and ../phase1/gen.sh.  The CPU sources cpu.v + ALU.v
# are Arlet Ottens' verilog-6502 (fetched verbatim, see README.md for provenance
# + license); soc.v / soc_tb.v are written for this fixture.  Everything else in
# this directory is REAL Yosys / Icarus tool output produced by this script and
# reproduces byte-for-byte on the pinned tools (see ../phase0/NOTES.md):
# yosys 0.33, iverilog/vvp 12.0.
#
#   ./gen.sh
#
# NOTE: there is intentionally NO Tcl test driving the engine here -- the engine
# cannot run this yet (it needs the DFF latch + settle loop wired, and the
# coarse flow needs $mem).  This script only produces the fixtures + cross-check.
set -euo pipefail
cd "$(dirname "$0")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "gen.sh: missing tool: $1" >&2; exit 127; }; }
need yosys ; need iverilog ; need vvp

echo "== Yosys: COARSE synth (keeps the regfile as \$mem, word-level kept) =="
# Natural synth+techmap of the standalone CPU core.  Leaves the 4x8 register
# file as $memrd/$memwr_v2 and emits the rich flip-flop family ($_DFFE_*,
# $_SDFFE_*, $_SDFFCE_*).  This is what the engine would need native $mem +
# the full DFF family to consume.
yosys -q -p '
    read_verilog ALU.v cpu.v
    hierarchy -check -top cpu
    flatten
    proc
    opt
    techmap
    opt
    write_json cpu6502.coarse.json
    tee -o cpu6502.coarse.stat.txt stat
' 2>/dev/null

echo "== Yosys: BIT-BLASTED synth of the CPU core (engine cell set only) =="
# memory_map bit-blasts the 4x8 regfile to flip-flops; async2sync turns the
# async reset into synchronous logic; dfflegalize with huge -mince/-minsrst
# unmaps every clock-enable and sync-reset into soft MUX logic, leaving ONLY
# plain $_DFF_P_ flops.  Result = gates + $_MUX_ + $_DFF_P_ : exactly the
# engine's current cell set.  opt_dff is NOT run afterwards (it would re-infer
# the enables/resets we just unmapped).
yosys -q -p '
    read_verilog ALU.v cpu.v
    hierarchy -check -top cpu
    flatten
    proc
    opt
    memory_map
    opt
    techmap
    opt
    async2sync
    opt
    dfflegalize -cell $_DFF_P_ 0 -mince 999999 -minsrst 999999
    opt_clean
    write_json cpu6502.synth.json
    write_verilog -noattr cpu6502.synth.v
    tee -o cpu6502.synth.stat.txt stat
' 2>/dev/null

echo "== Yosys: BIT-BLASTED synth of the WHOLE SoC (CPU + 2KB RAM as FFs) =="
# Same recipe applied to soc.v.  memory_map bit-blasts BOTH the regfile AND the
# 2 KB RAM into flip-flops + read muxes, so the entire CPU+RAM is engine cells.
# WARNING: a 2 KB RAM bit-blasts to ~16k flops + a huge read mux -- this is the
# "small memories bit-blast to DFFs+muxes" demonstration, not a recommended way
# to run real memory (that is what the engine's $mem brick is for).  We capture
# only the cell-count stat (soc.synth.stat.txt); the full JSON is ~30 MB and not
# committed -- the point is the inventory, not the giant netlist.
yosys -q -p '
    read_verilog ALU.v cpu.v soc.v
    hierarchy -check -top soc
    flatten
    proc
    opt
    memory_map
    opt
    techmap
    opt
    async2sync
    opt
    dfflegalize -cell $_DFF_P_ 0 -mince 999999 -minsrst 999999
    opt_clean
    tee -o soc.synth.stat.txt stat
' 2>/dev/null

echo "== Icarus: RTL reference per-cycle trace + VCD =="
iverilog -o /tmp/soc_rtl.vvp soc_tb.v soc.v cpu.v ALU.v
vvp /tmp/soc_rtl.vvp | grep -E '^cycle [0-9]+ ' > cpu6502.ref.trace

echo "== Icarus: gate-level re-sim of the bit-blasted CPU (must equal RTL) =="
# Re-wrap the synthesized CPU netlist in the SAME soc.v harness + testbench and
# confirm it reproduces the RTL oracle bit-for-bit (the phase0 cross-check).
# cpu6502.synth.v defines module `cpu`, so it drops in for cpu.v + ALU.v.
iverilog -o /tmp/soc_gl.vvp soc_tb.v soc.v cpu6502.synth.v
vvp /tmp/soc_gl.vvp | grep -E '^cycle [0-9]+ ' > cpu6502.gl.trace

if diff -q cpu6502.ref.trace cpu6502.gl.trace >/dev/null; then
    echo "OK: synthesized CPU netlist re-simulates bit-identically to the RTL oracle."
else
    echo "MISMATCH: gate-level trace differs from RTL oracle" >&2
    diff cpu6502.ref.trace cpu6502.gl.trace | head >&2
    exit 1
fi
echo "Done.  Fixtures regenerated in $(pwd)."
