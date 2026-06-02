#!/usr/bin/env wish
# test_ksym.tcl -- the KiCad symbol importer.  Asserts the vendored standards-
# compliant symbols parse, expose the right engine terminal names, and render
# with pin coordinates.  Needs Tk (a canvas) but no display interaction.
catch {encoding system utf-8}
if {[catch {package require Tk}]} { puts "# no Tk -- skipped" ; puts "0 passed, 0 failed" ; exit 0 }
if {[catch {wm withdraw .}]} { puts "# no display -- skipped" ; puts "0 passed, 0 failed" ; exit 0 }
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. src symbols.tcl]
source [file join $here .. src ksym.tcl]

set ::T 0 ; set ::F 0
proc ok {n c} { if {[uplevel 1 [list expr $c]]} { incr ::T ; puts "ok   - $n" } else { incr ::F ; puts "FAIL - $n" } }
proc section {t} { puts "\n# $t" }

canvas .c

section "library loads and key symbols exist"
ok "diode present"        {[::schem::ksym::has diode]}
ok "battery present"      {[::schem::ksym::has battery]}
ok "NPN present"          {[::schem::ksym::has bjt_npn]}
ok "NMOS present"         {[::schem::ksym::has nmos]}
ok "AC source present"    {[::schem::ksym::has vsource]}
ok "ground present"       {[::schem::ksym::has ground]}

section "pins map to engine terminal names"
set d [::schem::ksym::draw .c diode 100 100 -scale 0.2]
ok "diode has a and k"   {[lsort [dict keys [dict get $d pins]]] eq {a k}}
set b [::schem::ksym::draw .c battery 100 100 -scale 0.2]
ok "battery has pos/neg" {[lsort [dict keys [dict get $b pins]]] eq {neg pos}}
set q [::schem::ksym::draw .c bjt_npn 100 100 -scale 0.2]
ok "NPN has b,c,e"       {[lsort [dict keys [dict get $q pins]]] eq {b c e}}
set m [::schem::ksym::draw .c nmos 100 100 -scale 0.2]
ok "NMOS has d,g,s"     {[lsort [dict keys [dict get $m pins]]] eq {d g s}}
set v [::schem::ksym::draw .c vsource 100 100 -scale 0.2]
ok "AC src has pos/neg"  {[lsort [dict keys [dict get $v pins]]] eq {neg pos}}
set g [::schem::ksym::draw .c ground 100 100 -scale 0.2]
ok "ground has t"        {[dict keys [dict get $g pins]] eq {t}}

section "diode geometry is a diode, not an SCR (2 pins, not 3)"
ok "diode is 2-terminal"  {[llength [dict keys [dict get $d pins]]] == 2}

section "unified draw2 falls back for non-KiCad types"
# relay has no KiCad symbol here -> falls back to hand-drawn, still returns pins
set r [::schem::sym::draw2 .c relay 100 100 -scale 1.0]
ok "relay still draws (fallback)" {[dict exists $r pins] && [dict size [dict get $r pins]] >= 3}
# diode via draw2 uses KiCad and returns offset pins
set d2 [::schem::sym::draw2 .c diode 200 200 -scale 1.2]
ok "draw2 diode returns a,k"      {[lsort [dict keys [dict get $d2 pins]]] eq {a k}}

section "rendered diode conducts the right way (engine cross-check)"
set s [::schem::new t]
$s add battery V -emf 5 ; $s add resistor R -r 1000 ; $s add diode D ; $s add ground G
$s wire V.pos R.a ; $s wire R.b D.a ; $s wire D.k G.t ; $s wire V.neg G.t
$s solve
ok "forward bias conducts"   {[$s current D] > 0.003}
# reverse: swap diode -> blocks
set s2 [::schem::new t2]
$s2 add battery V -emf 5 ; $s2 add resistor R -r 1000 ; $s2 add diode D ; $s2 add ground G
$s2 wire V.pos R.a ; $s2 wire R.b D.k ; $s2 wire D.a G.t ; $s2 wire V.neg G.t
$s2 solve
ok "reverse bias blocks"     {abs([$s2 current D]) < 1e-6}

puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
