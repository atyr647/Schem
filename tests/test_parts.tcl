#!/usr/bin/env tclsh
# test_parts.tcl -- real parts with datasheet specs, and the ratings review.
# Asserts that placing a real part applies its SPICE model, that the catalog
# queries work, and -- the point ET1 made -- that the same circuit passes or
# fails the design review depending on whether the chosen part can do the job.
#
#   tclsh tests/test_parts.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib parts parts.tcl]
source [file join $here .. lib parts ratings.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

# ====================================================================
section "the catalog"
# ====================================================================
ok "known parts are registered"   {[llength [::schem::parts::ids]] >= 15}
ok "1N4007 is a diode"            {[dict get [::schem::parts::get 1N4007] type] eq "diode"}
ok "query by type finds diodes"  {"1N4007" in [::schem::parts::byType diode]}
ok "query by category"           {"1N4007" in [::schem::parts::byCategory rectifier]}
ok "categories are listed"       {"rectifier" in [::schem::parts::categories]}
ok "unknown part errors"         {[catch {::schem::parts::get NOPART}]}

# ====================================================================
section "placing a real part applies its SPICE model"
# ====================================================================
set s [schem::new t]
$s add ground GND
::schem::parts::place $s D1 1N5819
ok "place creates the primitive"  {[$s typeof D1] eq "diode"}
ok "Schottky BV from datasheet"   {[$s get D1 bv] == 40}
ok "Schottky IS from model"       {abs([$s get D1 is] - 3.2e-5) < 1e-9}
ok "instance is tagged its id"    {[::schem::parts::idOf $s D1] eq "1N5819"}

# real model -> real behaviour: a Schottky drops less than a silicon rectifier
set sa [schem::new a] ; $sa add battery V -emf 5 ; $sa add ground G
::schem::parts::place $sa D 1N4007 ; $sa add resistor R -r 100
$sa wire V.pos D.a ; $sa wire D.k R.a ; $sa wire R.b G.t ; $sa wire V.neg G.t ; $sa solve
set vSi [expr {5 - [$sa probe D.k]}]
set sb [schem::new b] ; $sb add battery V -emf 5 ; $sb add ground G
::schem::parts::place $sb D 1N5819 ; $sb add resistor R -r 100
$sb wire V.pos D.a ; $sb wire D.k R.a ; $sb wire R.b G.t ; $sb wire V.neg G.t ; $sb solve
set vSch [expr {5 - [$sb probe D.k]}]
ok "Schottky drops less than silicon" {$vSch < $vSi}

# ====================================================================
section "ratings review -- same circuit, right vs wrong part"
# ====================================================================
proc rectifier {part} {
    set s [schem::new r]
    $s add battery V -emf 12 ; $s add ground G
    ::schem::parts::place $s D1 $part
    $s add resistor RL -r 47
    $s wire V.pos D1.a ; $s wire D1.k RL.a ; $s wire RL.b G.t ; $s wire V.neg G.t
    $s solve
    return $s
}
proc verdicts {s} {
    set v [dict create]
    foreach r [::schem::ratings::check $s] {
        dict set v "[dict get $r part].[dict get $r limit]" [dict get $r verdict]
    }
    return $v
}

set good [verdicts [rectifier 1N4007]]
ok "1N4007 forward current is OK"  {[dict get $good D1.If] eq "ok"}
set bad [verdicts [rectifier 1N4148]]
ok "1N4148 forward current OVER"   {[dict get $bad D1.If] eq "over"}

# capacitor voltage rating
proc capRail {emf part} {
    set s [schem::new c]
    $s add battery V -emf $emf ; $s add ground G
    ::schem::parts::place $s D1 1N4007
    ::schem::parts::place $s C1 $part
    $s add resistor RL -r 220
    $s wire V.pos D1.a ; $s wire D1.k C1.a ; $s wire C1.b G.t
    $s wire D1.k RL.a ; $s wire RL.b G.t ; $s wire V.neg G.t
    $s solve ; return $s
}
ok "16V cap on 24V rail is OVER"   {[dict get [verdicts [capRail 24 CAP_1000u_16V]] C1.Vdc] eq "over"}
ok "35V cap on 24V rail is OK"     {[dict get [verdicts [capRail 24 CAP_470u_35V]]  C1.Vdc] eq "ok"}

# ====================================================================
section "report text groups by verdict"
# ====================================================================
set rep [::schem::ratings::report [rectifier 1N4148]]
ok "report flags OVER LIMIT"       {[string match "*OVER LIMIT*" $rep]}
ok "report names the part+limit"   {[string match "*1N4148*If*" $rep]}
set repok [::schem::ratings::report [rectifier 1N4007]]
ok "clean design says within"      {[string match "*within ratings*" $repok] || [string match "*OK:*" $repok]}

# ====================================================================
section "marginal band (derating)"
# ====================================================================
# a load that pushes the 1N4007 to ~85% of its 1 A rating -> marginal
set s [schem::new m]
$s add battery V -emf 12 ; $s add ground G
::schem::parts::place $s D1 1N4007
$s add resistor RL -r 13     ;# ~0.87 A
$s wire V.pos D1.a ; $s wire D1.k RL.a ; $s wire RL.b G.t ; $s wire V.neg G.t
$s solve
ok "85% of rating reads marginal"  {[dict get [verdicts $s] D1.If] eq "marginal"}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
