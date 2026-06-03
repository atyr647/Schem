#!/usr/bin/env tclsh
# test_fpga2.tcl -- SECOND end-to-end cycle-accurate FPGA path, verified against
# Icarus.  Companion to test_fpga.tcl (the phase 0 counter): proves the
# Yosys-import + interpreted-kernel path generalizes beyond the counter.
#
# The design under test is a 4-bit up/down counter with synchronous load and
# count-enable (experiments/fpga/phase1/updown.v), synthesized by Yosys to a
# generic gate-level netlist of $_SDFFE_PP0P_ flip-flops + $_MUX_/$_AND_/$_OR_/
# $_XOR_/$_NOT_ logic (updown.synth.json).  We import it to the digital-netlist
# IR, run it cycle-by-cycle through the interpreted kernel driving the SAME
# stimulus as updown_tb.v, and assert the per-cycle q trace is BIT-IDENTICAL to
# the committed Icarus reference (updown.ref.trace).  Same verify-against-an-
# independent-reference ethos as test_fpga.tcl.
#
# It also unit-checks the new compound/inverting combinational cell evals added
# to cells.tcl ($_ANDNOT_/$_ORNOT_/$_AOI3_/$_OAI3_/$_AOI4_/$_OAI4_/$_NMUX_),
# directly against their Yosys simcells.v truth.
#
# Uses only committed fixtures; needs no yosys/iverilog at test time.
# Regenerate the fixtures with experiments/fpga/phase1/gen.sh.

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

# ====================================================================
section "new combinational cell evals match Yosys simcells.v truth"
# ====================================================================
# Reference truth (1-bit) straight from /usr/share/yosys/simcells.v.
proc refANDNOT {a b} { expr {$a & !$b & 1} }
proc refORNOT  {a b} { expr {$a | !$b & 1} }
proc refAOI3 {a b c}   { expr {!(($a & $b) | $c) & 1} }
proc refOAI3 {a b c}   { expr {!(($a | $b) & $c) & 1} }
proc refAOI4 {a b c d} { expr {!(($a & $b) | ($c & $d)) & 1} }
proc refOAI4 {a b c d} { expr {!(($a | $b) & ($c | $d)) & 1} }   ;# OR on the C,D leg
proc refNMUX {s a b}   { expr {($s ? !$b : !$a) & 1} }

set okAN 1 ; set okOR 1
foreach a {0 1} { foreach b {0 1} {
    if {[lindex [::schem::digital::Gate_eval ANDNOT $a $b] 0] != [refANDNOT $a $b]} { set okAN 0 }
    if {[lindex [::schem::digital::Gate_eval ORNOT  $a $b] 0] != [refORNOT  $a $b]} { set okOR 0 }
}}
ok "ANDNOT eval (Y=A&~B) over all inputs" {$okAN}
ok "ORNOT  eval (Y=A|~B) over all inputs" {$okOR}

set okA3 1 ; set okO3 1
foreach a {0 1} { foreach b {0 1} { foreach c {0 1} {
    if {[lindex [::schem::digital::AOI3_eval $a $b $c] 0] != [refAOI3 $a $b $c]} { set okA3 0 }
    if {[lindex [::schem::digital::OAI3_eval $a $b $c] 0] != [refOAI3 $a $b $c]} { set okO3 0 }
}}}
ok "AOI3 eval (Y=~((A&B)|C)) over all inputs" {$okA3}
ok "OAI3 eval (Y=~((A|B)&C)) over all inputs" {$okO3}

set okA4 1 ; set okO4 1
foreach a {0 1} { foreach b {0 1} { foreach c {0 1} { foreach d {0 1} {
    if {[lindex [::schem::digital::AOI4_eval $a $b $c $d] 0] != [refAOI4 $a $b $c $d]} { set okA4 0 }
    if {[lindex [::schem::digital::OAI4_eval $a $b $c $d] 0] != [refOAI4 $a $b $c $d]} { set okO4 0 }
}}}}
ok "AOI4 eval (Y=~((A&B)|(C&D))) over all inputs" {$okA4}
ok "OAI4 eval (Y=~((A|B)&(C|D))) over all inputs" {$okO4}

set okNM 1
foreach s {0 1} { foreach a {0 1} { foreach b {0 1} {
    if {[lindex [::schem::digital::NMUX_eval $s $a $b] 0] != [refNMUX $s $a $b]} { set okNM 0 }
}}}
ok "NMUX eval (Y=~(S?B:A)) over all inputs" {$okNM}

# ====================================================================
section "importer maps the new Yosys bit-level cells with correct ports"
# ====================================================================
# A tiny inline netlist exercising every newly-mapped Yosys cell type; assert it
# imports to the right primitive with the right port wiring (ports verified
# against /usr/share/yosys/simcells.v).
set tiny {
  {"modules":{"m":{
    "ports":{"o":{"direction":"output","bits":[20]}},
    "cells":{
      "an": {"type":"$_ANDNOT_","connections":{"A":[3],"B":[4],"Y":[5]}},
      "on": {"type":"$_ORNOT_", "connections":{"A":[3],"B":[4],"Y":[6]}},
      "a3": {"type":"$_AOI3_",  "connections":{"A":[3],"B":[4],"C":[5],"Y":[7]}},
      "o3": {"type":"$_OAI3_",  "connections":{"A":[3],"B":[4],"C":[5],"Y":[8]}},
      "a4": {"type":"$_AOI4_",  "connections":{"A":[3],"B":[4],"C":[5],"D":[6],"Y":[9]}},
      "o4": {"type":"$_OAI4_",  "connections":{"A":[3],"B":[4],"C":[5],"D":[6],"Y":[10]}},
      "nm": {"type":"$_NMUX_",  "connections":{"A":[3],"B":[4],"S":[5],"Y":[11]}},
      "bf": {"type":"$_BUF_",   "connections":{"A":[3],"Y":[20]}}
    }
  }}}
}
set t [::schem::digital::yosys::parseString $tiny]
proc cellByName {ir name} {
    foreach c [dict get $ir cells] { if {[dict get $c name] eq $name} { return $c } }
    return ""
}
ok "ANDNOT imports to ANDNOT prim" {[dict get [cellByName $t an] type] eq "ANDNOT"}
ok "ORNOT imports to ORNOT prim"   {[dict get [cellByName $t on] type] eq "ORNOT"}
ok "AOI3 imports to AOI3 prim, ports A,B,C,Y" {
    [dict get [cellByName $t a3] type] eq "AOI3" &&
    [lsort [dict keys [dict get [cellByName $t a3] conn]]] eq {A B C Y}}
ok "OAI3 imports to OAI3 prim"     {[dict get [cellByName $t o3] type] eq "OAI3"}
ok "AOI4 imports to AOI4 prim, ports A,B,C,D,Y" {
    [dict get [cellByName $t a4] type] eq "AOI4" &&
    [lsort [dict keys [dict get [cellByName $t a4] conn]]] eq {A B C D Y}}
ok "OAI4 imports to OAI4 prim"     {[dict get [cellByName $t o4] type] eq "OAI4"}
ok "NMUX imports to NMUX prim, ports A,B,S,Y" {
    [dict get [cellByName $t nm] type] eq "NMUX" &&
    [lsort [dict keys [dict get [cellByName $t nm] conn]]] eq {A B S Y}}
ok "BUF imports to BUF prim, ports A,Y" {
    [dict get [cellByName $t bf] type] eq "BUF" &&
    [lsort [dict keys [dict get [cellByName $t bf] conn]]] eq {A Y}}

# ====================================================================
section "import the real synthesized up/down counter"
# ====================================================================
set p1 [file join $root experiments phase1]
set ir [::schem::digital::yosys::parse [file join $p1 updown.synth.json]]
ok "top module is updown"            {[dict get $ir name] eq "updown"}
ok "q is a 4-bit output"             {[llength [dict get $ir outputs q]] == 4}
ok "din is a 4-bit input"            {[llength [dict get $ir inputs din]] == 4}
ok "clk/rst/en/load/updn are inputs" {
    [dict exists $ir inputs clk] && [dict exists $ir inputs rst] &&
    [dict exists $ir inputs en]  && [dict exists $ir inputs load] &&
    [dict exists $ir inputs updn]}
ok "four enable+sync-reset flip-flops" {[llength [lmap c [dict get $ir cells] {
    expr {[dict get $c type] eq "DFF" ? $c : [continue]}}]] == 4}
# the SDFFE_PP0P_ variant: sync reset, active-high reset/clk/enable, rstval 0.
set ff [lindex [lmap c [dict get $ir cells] {
    expr {[dict get $c type] eq "DFF" ? $c : [continue]}}] 0]
ok "flip-flop is sync-reset + enabled" {
    [dict get $ff params async] == 0 && [dict get $ff params enable] == 1 &&
    [dict get $ff params rstpol] == 1 && [dict get $ff params rstval] == 0}

set lv [::schem::digital::levelize $ir]
ok "no combinational loops"          {[llength [dict get $lv loops]] == 0}
set order [dict get $lv order]

# ====================================================================
section "run cycle-accurately, diff against the Icarus oracle"
# ====================================================================
set clk  [lindex [dict get $ir inputs clk] 0]
set rst  [lindex [dict get $ir inputs rst] 0]
set en   [lindex [dict get $ir inputs en] 0]
set load [lindex [dict get $ir inputs load] 0]
set updn [lindex [dict get $ir inputs updn] 0]
set din  [dict get $ir inputs din]
set qn   [dict get $ir outputs q]   ;# LSB first

proc qval {netval qn} {
    set v 0 ; set i 0
    foreach n $qn { if {[dict get $netval $n]} { set v [expr {$v | (1 << $i)}] } ; incr i }
    return $v
}
proc setbits {designVar nets val} {
    upvar 1 $designVar design
    set i 0 ; foreach n $nets { dict set design stim $n [expr {($val >> $i) & 1}] ; incr i }
}
# one clock half-step: apply the clk level, tick, return the settled netval.
proc step {designVar stateVar order clk clkv} {
    upvar 1 $designVar design $stateVar state
    dict set design stim $clk $clkv
    set r [::schem::digital::tick $design $order $state]
    set state [dict get $r state]
    return [dict get $r netval]
}

set design $ir
set state [dict create q [dict create] cells [dict create] prevclk [dict create]]

# Mirror updown_tb.v: one reset rising edge clears q (controls idle), then the
# scripted 20-cycle stimulus.  Controls are applied while clk is low (stable at
# the edge), exactly as the testbench drives them on the negedge.
dict set design stim $en 0 ; dict set design stim $load 0 ; dict set design stim $updn 1
setbits design $din 0
step design state $order $clk 0                 ;# clk low, reset asserted
dict set design stim $rst 1
step design state $order $clk 0
step design state $order $clk 1                 ;# RISING edge under reset -> q=0
dict set design stim $rst 0
step design state $order $clk 0                 ;# clk low, reset released

# {en load updn din} per counted cycle 0..19 -- byte-for-byte the testbench script.
set script {
    {1 1 1 10} {1 0 1 0} {1 0 1 0} {1 0 1 0} {1 0 1 0} {1 0 1 0} {1 0 1 0}
    {0 0 1 0}  {1 0 0 0} {1 0 0 0} {1 0 0 0} {1 1 0 3} {1 0 0 0} {1 0 0 0}
    {1 0 0 0}  {1 0 0 0} {0 1 1 9} {1 0 1 0} {1 0 1 0} {1 1 1 7}
}
set lines {}
set n 0
foreach s $script {
    lassign $s e l u d
    dict set design stim $en $e ; dict set design stim $load $l ; dict set design stim $updn $u
    setbits design $din $d
    step  design state $order $clk 0            ;# clk low: apply controls
    set nv [step design state $order $clk 1]    ;# RISING edge -> commit
    lappend lines "cycle $n q=[qval $nv $qn]"
    incr n
}
set got [join $lines \n]

set fh [open [file join $p1 updown.ref.trace] r] ; fconfigure $fh -encoding utf-8
set want [string trim [read $fh]] ; close $fh

ok "load 10 lands on cycle 0"        {[lindex $lines 0] eq "cycle 0 q=10"}
ok "counts up then wraps 15->0"      {[lrange $lines 0 6] eq [list \
    "cycle 0 q=10" "cycle 1 q=11" "cycle 2 q=12" "cycle 3 q=13" \
    "cycle 4 q=14" "cycle 5 q=15" "cycle 6 q=0"]}
ok "disabled cycle 7 holds q=0"      {[lindex $lines 7] eq "cycle 7 q=0"}
ok "counts down then wraps 0->15"    {[lrange $lines 8 15] eq [list \
    "cycle 8 q=15" "cycle 9 q=14" "cycle 10 q=13" "cycle 11 q=3" \
    "cycle 12 q=2" "cycle 13 q=1" "cycle 14 q=0" "cycle 15 q=15"]}
ok "disabled cycle 16 ignores load"  {[lindex $lines 16] eq "cycle 16 q=15"}
ok "20-cycle trace == Icarus reference (bit-identical)" {$got eq $want}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
