#!/usr/bin/env tclsh
# test_fpga.tcl -- end-to-end cycle-accurate FPGA path, verified against Icarus.
#
# This is the Phase 1 milestone check: take a REAL Yosys-synthesized core
# (experiments/fpga/phase0/counter.synth.json, a generic gate-level netlist of
# $_SDFF_PP0_ flip-flops + an $_AND_/$_XOR_/$_NOT_ incrementer), import it to the
# digital-netlist IR, run it cycle-by-cycle through the interpreted kernel, and
# assert the per-cycle output is BIT-IDENTICAL to the Icarus Verilog reference
# trace (counter.ref.trace).  Same verify-against-an-independent-reference ethos
# as dcref vs the MNA engine -- here the reference is a real RTL simulator.
#
# Uses only committed fixtures; needs no yosys/iverilog at test time, so it is
# safe in headless CI.  Regenerate the fixtures with experiments/fpga/phase0/gen.sh.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
source [file join $root src digital cells.tcl]
source [file join $root src digital simkernel.tcl]
source [file join $root src digital import_yosys.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

set p0 [file join $root experiments fpga phase0]

# --------------------------------------------------------------------
section "import the real synthesized counter"
# --------------------------------------------------------------------
set ir [::schem::digital::yosys::parse [file join $p0 counter.synth.json]]
ok "top module is counter"           {[dict get $ir name] eq "counter"}
ok "imported all 24 cells"           {[llength [dict get $ir cells]] == 24}
ok "clk + rst are inputs"            {[dict exists $ir inputs clk] && [dict exists $ir inputs rst]}
ok "q is an 8-bit output"            {[llength [dict get $ir outputs q]] == 8}
ok "eight sync-reset flip-flops"     {[llength [lmap c [dict get $ir cells] {
                                          expr {[dict get $c type] eq "DFF" ? $c : [continue]}}]] == 8}

# combinational part must be a DAG (flip-flops cut the q -> +1 -> q loop).
set lv [::schem::digital::levelize $ir]
ok "no combinational loops"          {[llength [dict get $lv loops]] == 0}
set order [dict get $lv order]

# --------------------------------------------------------------------
section "run cycle-accurately, diff against the Icarus oracle"
# --------------------------------------------------------------------
set clk [lindex [dict get $ir inputs clk] 0]
set rst [lindex [dict get $ir inputs rst] 0]
set qn  [dict get $ir outputs q]   ;# LSB first

# read the byte value of q from a settled netval (LSB-first nets).
proc qval {netval qn} {
    set v 0 ; set i 0
    foreach n $qn { if {[dict get $netval $n]} { set v [expr {$v | (1 << $i)}] } ; incr i }
    return $v
}

# one clock half-step: apply (clk,rst) stimulus, tick, return the settled netval.
proc step {designVar stateVar order clk rst clkv rstv} {
    upvar 1 $designVar design $stateVar state
    dict set design stim $clk $clkv
    dict set design stim $rst $rstv
    set r [::schem::digital::tick $design $order $state]
    set state [dict get $r state]
    return [dict get $r netval]
}

set design $ir
set state [dict create q [dict create] cells [dict create] prevclk [dict create]]

# Mirror counter_tb.v: one reset rising edge clears q, then release reset and
# count 40 free-running rising edges, sampling q after each (q == (n+1)&0xFF).
step design state $order $clk $rst 0 1          ;# clk low,  reset asserted
step design state $order $clk $rst 1 1          ;# RISING edge under reset -> q=0
step design state $order $clk $rst 0 0          ;# clk low,  reset released

set lines {}
for {set n 0} {$n < 40} {incr n} {
    step  design state $order $clk $rst 0 0     ;# clk low
    set nv [step design state $order $clk $rst 1 0] ;# RISING edge -> count
    lappend lines "cycle $n q=[qval $nv $qn]"
}
set got [join $lines \n]

set fh [open [file join $p0 counter.ref.trace] r] ; fconfigure $fh -encoding utf-8
set want [string trim [read $fh]] ; close $fh

ok "q after reset edge is 0"         {[lindex $lines 0] eq "cycle 0 q=1"}
ok "first ten cycles count 1..10"    {[lrange $lines 0 9] eq [list \
    "cycle 0 q=1" "cycle 1 q=2" "cycle 2 q=3" "cycle 3 q=4" "cycle 4 q=5" \
    "cycle 5 q=6" "cycle 6 q=7" "cycle 7 q=8" "cycle 8 q=9" "cycle 9 q=10"]}
ok "40-cycle trace == Icarus reference (bit-identical)" {$got eq $want}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
