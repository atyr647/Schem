#!/usr/bin/env tclsh
# bench.tcl -- throughput of the compiled core driven as an emulator backend.
#
# Emits the counter as a loop-driven Zig host (emitZigBench), first checks it is
# still correct (40 cycles -> q=40), then runs a large timed loop compiled with
# -O ReleaseFast and prints clock-periods/second.  The counter is tiny (24
# cells), so this is an UPPER BOUND -- divide by ~(core_cells/24) to estimate a
# real core.  Honest scaling is the point.
set here [file dirname [file normalize [info script]]]
set root [file dirname [file dirname $here]]   ;# fpga/
foreach f {cells.tcl simkernel.tcl import_yosys.tcl zig.tcl} {
    source [file join $root src digital $f]
}
proc zigExe {} {
    if {[info exists ::env(SCHEM_ZIG)] && [file executable $::env(SCHEM_ZIG)]} { return $::env(SCHEM_ZIG) }
    set p [auto_execok zig] ; if {$p ne ""} { return $p }
    foreach c [glob -nocomplain /tmp/zig-*/zig] { if {[file executable $c]} { return $c } }
    return ""
}
set zig [zigExe]
if {$zig eq ""} { puts "no zig; set SCHEM_ZIG" ; exit 0 }

set ir [::schem::digital::yosys::parse [file join $here .. phase0 counter.synth.json]]
set order [dict get [::schem::digital::levelize $ir] order]
set clk [lindex [dict get $ir inputs clk] 0]
set rst [lindex [dict get $ir inputs rst] 0]
set qn  [dict get $ir outputs q]
set cells [llength [dict get $ir cells]]

proc run1 {zig src args} {
    set zf /tmp/bench[pid].zig
    set ch [open $zf w] ; puts $ch $src ; close $ch
    set out [exec {*}$zig run {*}$args $zf]
    file delete $zf
    return [string trim $out]
}

# 1) correctness: 1 reset cycle, 40 counting cycles -> q should be 40.
set src [::schem::digital::emitZigBench $ir $order $clk $rst 1 40 $qn q]
set out [run1 $zig $src]
puts "verify: $out"
if {![regexp {q=40 } $out]} { puts "FAIL: expected q=40" ; exit 1 }

# 2) throughput: 100M clock periods, optimized.
set N 100000000
set src [::schem::digital::emitZigBench $ir $order $clk $rst 1 $N $qn q]
set out [run1 $zig $src -O ReleaseFast]
puts "bench ($cells cells): $out"
regexp {Mcyc_per_s=([0-9.]+)} $out -> mcps
puts ""
puts "counter: ${mcps} Mcyc/s on $cells cells."
puts "scale estimate for a ~30k-cell core (NES-ish): ~[format %.3f [expr {$mcps*$cells/30000.0}]] Mcyc/s"
puts "(NES master clock is ~21.5 MHz; CPU ~1.79 MHz.)"
