#!/usr/bin/env tclsh
# test_acdc.tcl -- the time-varying source (vsource) and AC-DC rectification.
# Asserts the sinusoid is correct at DC and over time, and that a bridge
# rectifier + reservoir actually produces smoothed DC with bounded ripple.
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib parts parts.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }
proc approx {a b {tol 0.05}} { expr {abs($a-$b) <= $tol} }

# ====================================================================
section "vsource waveform"
# ====================================================================
# DC op point sits at the offset (sin(0)=0 unless phase set)
set s [schem::new v]
$s add vsource AC -vac 10 -freq 50 -voff 3
$s add resistor R -r 1000 ; $s add ground G
$s wire AC.pos R.a ; $s wire R.b G.t ; $s wire AC.neg G.t
$s solve
ok "DC op = voff"             {[approx [$s probe R.a] 3.0]}

# quarter period later the sine peaks at voff+vac
$s tnow [expr {1.0/50/4}]    ;# t = T/4 -> sin = 1
$s solve
ok "at T/4 source peaks"      {[approx [$s probe R.a] 13.0 0.2]}

# half period: back to offset
$s tnow [expr {1.0/50/2}]
$s solve
ok "at T/2 source = offset"   {[approx [$s probe R.a] 3.0 0.2]}

# ====================================================================
section "transient traces a sinusoid"
# ====================================================================
set s [schem::new tr]
$s add vsource AC -vac 5 -freq 100 -voff 0
$s add resistor R -r 1000 ; $s add ground G
$s wire AC.pos R.a ; $s wire R.b G.t ; $s wire AC.neg G.t
set res [$s run -duration 0.02 -dt 1e-4 -record {R.a}]
set vs [dict get $res R.a]
set mx [lindex [lsort -real $vs] end] ; set mn [lindex [lsort -real $vs] 0]
ok "swing reaches +/- vac"    {[approx $mx 5.0 0.2] && [approx $mn -5.0 0.2]}

# ====================================================================
section "AC-DC: bridge rectifier smooths to DC"
# ====================================================================
set s [schem::new acdc]
$s add vsource SEC -vac 17 -freq 60 -voff 0
$s add ground GND
foreach d {D1 D2 D3 D4} { ::schem::parts::place $s $d 1N4007 }
$s add capacitor C1 -c 1000e-6
$s add resistor RL -r 68
$s wire SEC.pos D1.a ; $s wire SEC.pos D2.k
$s wire SEC.neg D3.a ; $s wire SEC.neg D4.k
$s wire D1.k C1.a ; $s wire D3.k C1.a
$s wire D2.a GND.t ; $s wire D4.a GND.t
$s wire C1.a RL.a ; $s wire C1.b GND.t ; $s wire RL.b GND.t
set res [$s run -duration 0.06 -dt 5e-5 -record {RL.a}]
set vo [dict get $res RL.a] ; set n [llength $vo]
set win {} ; for {set i [expr {$n*2/3}]} {$i < $n} {incr i} { lappend win [lindex $vo $i] }
set sorted [lsort -real $win]
set vmax [lindex $sorted end] ; set vmin [lindex $sorted 0]
set vdc [expr {($vmax+$vmin)/2}]
ok "output is DC near peak"   {$vdc > 12 && $vdc < 16}
ok "ripple is bounded"        {[expr {$vmax-$vmin}] < 3.0}
ok "output never reverses"    {$vmin > 0}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
