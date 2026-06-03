#!/usr/bin/env bash
# gen.sh -- regenerate the Phase 1 ground-truth fixtures from the committed RTL.
#
# Mirrors phase0/gen.sh.  Everything in this directory except the *.v sources is
# REAL tool output produced by this script and reproduces byte-for-byte on the
# pinned tools (see ../phase0/NOTES.md for versions): yosys, iverilog/vvp.
#
#   ./gen.sh
#
# The cycle-accurate engine (tests/test_fpga2.tcl) diffs its own per-cycle output
# against updown.ref.trace; this script is how that oracle is (re)produced.
set -euo pipefail
cd "$(dirname "$0")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "gen.sh: missing tool: $1" >&2; exit 127; }; }
need yosys ; need iverilog ; need vvp

echo "== Yosys: synthesize generic gate-level + coarse netlists =="
yosys -q -p 'read_verilog updown.v; proc; opt; techmap; opt; write_json updown.synth.json'
yosys -q -p 'read_verilog updown.v; synth;                    write_json updown.coarse.json'
# Re-emit the synthesized netlist as Verilog, for the self-consistency cross-check.
yosys -q -p 'read_verilog updown.v; proc; opt; techmap; opt; write_verilog -noattr updown.synth.v'

echo "== Icarus: RTL reference per-cycle trace + VCD =="
iverilog -o /tmp/updown_rtl.vvp updown_tb.v updown.v
vvp /tmp/updown_rtl.vvp | grep -E '^cycle [0-9]+ q=[0-9]+$' > updown.ref.trace

echo "== Icarus: gate-level re-sim (must equal the RTL trace) =="
iverilog -o /tmp/updown_gl.vvp updown_tb.v updown.synth.v
vvp /tmp/updown_gl.vvp | grep -E '^cycle [0-9]+ q=[0-9]+$' > updown.gl.trace

if diff -q updown.ref.trace updown.gl.trace >/dev/null; then
    echo "OK: synthesized netlist re-simulates bit-identically to the RTL oracle."
else
    echo "MISMATCH: gate-level trace differs from RTL oracle" >&2 ; exit 1
fi
echo "Done.  Fixtures regenerated in $(pwd)."
