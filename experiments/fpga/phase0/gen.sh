#!/usr/bin/env bash
# gen.sh -- regenerate the Phase 0 ground-truth fixtures from the committed RTL.
#
# Everything in this directory except the *.v sources and NOTES.md is REAL tool
# output produced by this script.  It is deterministic: the synthesized netlists
# and the per-cycle oracle trace reproduce byte-for-byte on the pinned tools.
#
# Requires (see NOTES.md for versions): yosys, iverilog/vvp (Icarus Verilog).
# Verilator is not needed to regenerate -- Icarus is the reference simulator.
#
#   ./gen.sh
#
# The cycle-accurate engine (src/digital/, tests/test_*) diffs its own output
# against counter.ref.trace; this script is how that oracle is (re)produced.
set -euo pipefail
cd "$(dirname "$0")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "gen.sh: missing tool: $1" >&2; exit 127; }; }
need yosys ; need iverilog ; need vvp

echo "== Yosys: synthesize generic gate-level + coarse netlists =="
yosys -q -p 'read_verilog counter.v; proc; opt; techmap; opt; write_json counter.synth.json'
yosys -q -p 'read_verilog counter.v; synth;                    write_json counter.coarse.json'
yosys -q -p 'read_verilog blinky.v;  proc; opt; techmap; opt; write_json blinky.synth.json'
yosys -q -p 'read_verilog blinky.v;  synth;                    write_json blinky.coarse.json'
# Re-emit the synthesized netlist as Verilog, for the self-consistency cross-check.
yosys -q -p 'read_verilog counter.v; proc; opt; techmap; opt; write_verilog -noattr counter.synth.v'

echo "== Icarus: RTL reference per-cycle trace + VCD =="
iverilog -o /tmp/counter_rtl.vvp counter_tb.v counter.v
# The testbench writes counter.ref.vcd via $dumpfile; filter to pure oracle lines.
vvp /tmp/counter_rtl.vvp | grep -E '^cycle [0-9]+ q=[0-9]+$' > counter.ref.trace

echo "== Icarus: gate-level re-sim (must equal the RTL trace) =="
iverilog -o /tmp/counter_gl.vvp counter_tb.v counter.synth.v
vvp /tmp/counter_gl.vvp | grep -E '^cycle [0-9]+ q=[0-9]+$' > counter.gl.trace

if diff -q counter.ref.trace counter.gl.trace >/dev/null; then
    echo "OK: synthesized netlist re-simulates bit-identically to the RTL oracle."
else
    echo "MISMATCH: gate-level trace differs from RTL oracle" >&2 ; exit 1
fi
echo "Done.  Fixtures regenerated in $(pwd)."
