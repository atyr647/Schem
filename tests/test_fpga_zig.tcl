#!/usr/bin/env tclsh
# test_fpga_zig.tcl -- the compiled (Zig) FPGA path, triple-verified.
#
# Phase 2: emit the digital netlist as a native Zig cycle simulator, compile and
# run it, and assert its per-cycle trace agrees with BOTH the interpreted kernel
# (simkernel.tcl) AND the Icarus Verilog reference (counter.ref.trace).  Three
# independent implementations agreeing cycle-for-cycle is the strongest evidence
# the compiled path is faithful -- the same discipline as zig vs dcref vs the
# engine elsewhere in Schem.
#
# Skips cleanly when no Zig compiler is present (set SCHEM_ZIG, or put `zig` on
# PATH); uses only committed fixtures otherwise.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
foreach f {cells.tcl simkernel.tcl import_yosys.tcl zig.tcl} {
    source [file join $root src digital $f]
}

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}

# locate a zig compiler (env, PATH, or the pinned download the CI/dev box uses).
proc zigExe {} {
    if {[info exists ::env(SCHEM_ZIG)] && [file executable $::env(SCHEM_ZIG)]} {
        return $::env(SCHEM_ZIG)
    }
    set p [auto_execok zig] ; if {$p ne ""} { return $p }
    foreach c [glob -nocomplain /tmp/zig-*/zig] { if {[file executable $c]} { return $c } }
    return ""
}

set p0  [file join $root experiments fpga phase0]
set ir  [::schem::digital::yosys::parse [file join $p0 counter.synth.json]]
set order [dict get [::schem::digital::levelize $ir] order]

set clk [lindex [dict get $ir inputs clk] 0]
set rst [lindex [dict get $ir inputs rst] 0]
set qn  [dict get $ir outputs q]

# Build the SAME waveform test_fpga.tcl drives: one reset edge, then 40 counting
# edges; record q after each counting edge.  steps = {assign {net val ...} record}.
set steps {}
lappend steps [dict create assign [list $clk 0 $rst 1] record 0]
lappend steps [dict create assign [list $clk 1 $rst 1] record 0]
lappend steps [dict create assign [list $clk 0 $rst 0] record 0]
for {set n 0} {$n < 40} {incr n} {
    lappend steps [dict create assign [list $clk 0 $rst 0] record 0]
    lappend steps [dict create assign [list $clk 1 $rst 0] record 1]
}

# --- reference: the Icarus oracle -----------------------------------------
set fh [open [file join $p0 counter.ref.trace] r] ; fconfigure $fh -encoding utf-8
set oracle [string trim [read $fh]] ; close $fh

# --- the interpreted kernel, same steps (independent of Zig) ---------------
proc interpTrace {ir order steps qn} {
    set design $ir
    set state [dict create q [dict create] cells [dict create] prevclk [dict create]]
    set rec 0 ; set lines {}
    foreach step $steps {
        foreach {net val} [dict get $step assign] { dict set design stim $net $val }
        set r [::schem::digital::tick $design $order $state]
        set state [dict get $r state]
        if {[dict get $step record]} {
            set nv [dict get $r netval] ; set v 0 ; set i 0
            foreach b $qn { if {[dict get $nv $b]} { set v [expr {$v | (1 << $i)}] } ; incr i }
            lappend lines "cycle $rec q=$v" ; incr rec
        }
    }
    return [join $lines \n]
}
set interp [interpTrace $ir $order $steps $qn]
ok "interpreter still matches Icarus" {$interp eq $oracle}

# --- the compiled Zig simulator -------------------------------------------
set zig [zigExe]
if {$zig eq ""} {
    puts "ok   - (skipped: no zig compiler; set SCHEM_ZIG to enable)"
    incr ::T
} else {
    set src [::schem::digital::emitZig $ir $order $steps $qn q]
    set zf  [file join [file dirname [info script]] ztmp[pid].zig]
    set ch [open $zf w] ; fconfigure $ch -encoding utf-8 ; puts $ch $src ; close $ch
    if {[catch {exec {*}$zig run $zf} compiled]} {
        ok "zig compiles + runs" {0}
        puts "  zig error: $compiled"
    } else {
        ok "zig compiles + runs" {1}
        set compiled [string trim $compiled]
        ok "compiled trace == interpreter"      {$compiled eq $interp}
        ok "compiled trace == Icarus reference"  {$compiled eq $oracle}
    }
    file delete $zf
}

puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
