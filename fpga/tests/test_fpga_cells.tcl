#!/usr/bin/env tclsh
# test_fpga_cells.tcl -- the compound combinational cells, interp vs compiled.
#
# AOI3/OAI3/AOI4/OAI4/NMUX (the and-or-invert / or-and-invert / inverting-mux
# cells Yosys techmap emits) are exercised over EVERY input combination, and the
# interpreted kernel (settle) and the compiled Zig emitter are required to agree
# bit-for-bit -- so the two paths stay at parity as the cell set grows.  Skips
# the compiled half cleanly when no Zig compiler is present.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
foreach f {cells.tcl simkernel.tcl zig.tcl} { source [file join $root src digital $f] }

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc zigExe {} {
    if {[info exists ::env(SCHEM_ZIG)] && [file executable $::env(SCHEM_ZIG)]} { return $::env(SCHEM_ZIG) }
    set p [auto_execok zig] ; if {$p ne ""} { return $p }
    foreach c [glob -nocomplain /tmp/zig-*/zig] { if {[file executable $c]} { return $c } }
    return ""
}

# A comb-only design: inputs A,B,C,D,S (nets 3..7) feed all five cells; the five
# outputs (nets 8..12) form the observed bus.  No clock -> pure settle.
set A 3 ; set B 4 ; set C 5 ; set D 6 ; set S 7
set bus {8 9 10 11 12}
set ir [dict create name cells nbits 13 clocks {} \
    inputs  [dict create A [list $A] B [list $B] C [list $C] D [list $D] S [list $S]] \
    outputs [dict create bus $bus] \
    cells [list \
        [dict create name aoi3 type AOI3 params {} conn [dict create A [list $A] B [list $B] C [list $C] Y [list 8]]] \
        [dict create name oai3 type OAI3 params {} conn [dict create A [list $A] B [list $B] C [list $C] Y [list 9]]] \
        [dict create name aoi4 type AOI4 params {} conn [dict create A [list $A] B [list $B] C [list $C] D [list $D] Y [list 10]]] \
        [dict create name oai4 type OAI4 params {} conn [dict create A [list $A] B [list $B] C [list $C] D [list $D] Y [list 11]]] \
        [dict create name nmux type NMUX params {} conn [dict create S [list $S] A [list $A] B [list $B] Y [list 12]]] \
    ]]
set order [dict get [::schem::digital::levelize $ir] order]
ok "five comb cells, no loop"        {[llength $order] == 5}

# all 32 combinations of (A,B,C,D,S).
set steps {}
for {set m 0} {$m < 32} {incr m} {
    lappend steps [dict create record 1 assign [list \
        $A [expr {$m & 1}] $B [expr {($m>>1)&1}] $C [expr {($m>>2)&1}] \
        $D [expr {($m>>3)&1}] $S [expr {($m>>4)&1}]]]
}

proc interpLines {ir order steps bus} {
    set design $ir
    set state [dict create q [dict create] cells [dict create] prevclk [dict create]]
    set rec 0 ; set lines {}
    foreach step $steps {
        foreach {n v} [dict get $step assign] { dict set design stim $n $v }
        set r [::schem::digital::tick $design $order $state] ; set state [dict get $r state]
        set nv [dict get $r netval] ; set val 0 ; set i 0
        foreach b $bus { if {[dict get $nv $b]} { set val [expr {$val | (1 << $i)}] } ; incr i }
        lappend lines "cycle $rec v=$val" ; incr rec
    }
    return [join $lines \n]
}
set interp [interpLines $ir $order $steps $bus]

# Hand-checked spot value.  m=3 -> A=1 B=1 C=0 D=0 S=0:
#   aoi3=~((1&1)|0)=0  oai3=~((1|1)&0)=1  aoi4=~((1&1)|(0&0))=0
#   oai4=~((1|1)&(0|0))=1  nmux=~(0?B:A)=~A=0  -> bus bit1,bit3 set = 2|8 = 10
ok "compound-cell spot value (m=3)" {[lindex [split $interp \n] 3] eq "cycle 3 v=10"}
ok "all 32 combinations recorded"    {[llength [split $interp \n]] == 32}

set zig [zigExe]
if {$zig eq ""} {
    puts "ok   - (skipped: no zig compiler; set SCHEM_ZIG to enable)" ; incr ::T
} else {
    set src [::schem::digital::emitZig $ir $order $steps $bus v]
    set zf [file join [file dirname [info script]] ztmpcells[pid].zig]
    set ch [open $zf w] ; fconfigure $ch -encoding utf-8 ; puts $ch $src ; close $ch
    if {[catch {exec {*}$zig run $zf} compiled]} {
        ok "zig compiles + runs" {0} ; puts "  zig error: $compiled"
    } else {
        ok "compiled compound cells == interpreter (all 32)" {[string trim $compiled] eq $interp}
    }
    file delete $zf
}

puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
