#!/usr/bin/env wish
# test_gui.tcl -- the Tk workbench, driven headlessly via its `do` interface.
# Requires a display (run under Xvfb).  Asserts that placing parts builds the
# model, wiring connects pins, solving + reviewing flag bad parts, and the
# ANSI/IEC toggle and delete behave.
#
#   xvfb-run -a wish tests/test_gui.tcl      (or DISPLAY=:99 wish ...)
catch {encoding system utf-8}
# This suite needs Tk and a display.  When run without them (e.g. under tclsh
# in CI, or with no X server), skip cleanly rather than fail.
if {[catch {package require Tk}]} {
    puts "# test_gui: Tk unavailable -- skipped (run under: DISPLAY=:N wish tests/test_gui.tcl)"
    puts "0 passed, 0 failed"
    exit 0
}
if {[catch {wm withdraw .}]} {
    puts "# test_gui: no display -- skipped"
    puts "0 passed, 0 failed"
    exit 0
}
wm deiconify .
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. src symbols.tcl]
source [file join $here .. lib parts.tcl]
source [file join $here .. lib ratings.tcl]
source [file join $here .. src gui.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

set app [::schem::gui::App new]
set s [$app schematic]
update idletasks

# ====================================================================
section "placing parts builds the model"
# ====================================================================
$app do pick-primitive battery ; $app do click 200 200
ok "primitive places a component"  {[llength [$app do placed]] == 1}
ok "model gained the part"         {[llength [$s components]] == 1}
ok "auto-named BT1"                {"BT1" in [$app do placed]}

$app do pick-part 1N4007 ; $app do click 400 200
ok "real part places"              {"D1" in [$app do placed]}
ok "real part applied its model"   {[$s get D1 bv] == 1000}
ok "real part tagged its id"       {[::schem::parts::idOf $s D1] eq "1N4007"}

# ====================================================================
section "wiring connects pins in the model"
# ====================================================================
$app do pick-primitive resistor ; $app do click 600 200
$app do pick-primitive ground ;   $app do click 400 400
$s set BT1 emf 12 ; $s set R1 r 47
ok "wire joins two terminals"      {[$app do wire BT1.pos D1.a] == 1}
$app do wire D1.k R1.a
$app do wire R1.b GND1.t
$app do wire BT1.neg GND1.t
ok "all wires recorded"            {[llength [$app do wires]] == 4}
ok "model has the couplings"       {[llength [$s conns]] >= 4}

# ====================================================================
section "solve + probe"
# ====================================================================
$app do command solve
ok "solve sets result=solved"      {[$app do result] eq "solved"}
ok "node voltage is readable"      {![catch {$s probe R1.a}]}

# ====================================================================
section "design review flags the wrong part"
# ====================================================================
# 1N4007 at 0.25 A is fine; swap to a 1N4148 by editing -> over limit.
# Build a fresh board with a 1N4148 rectifier.
set app2 [::schem::gui::App new [::schem::new bad]]
set s2 [$app2 schematic]
$app2 do pick-primitive battery ; $app2 do click 200 200
$app2 do pick-part 1N4148 ;       $app2 do click 400 200
$app2 do pick-primitive resistor ;$app2 do click 600 200
$app2 do pick-primitive ground ;  $app2 do click 400 400
$s2 set BT1 emf 12 ; $s2 set R1 r 47
$app2 do wire BT1.pos D1.a ; $app2 do wire D1.k R1.a
$app2 do wire R1.b GND1.t ; $app2 do wire BT1.neg GND1.t
$app2 do command review
ok "over-limit part marked 'over'" {[$app2 do verdict D1] eq "over"}
ok "good resistor stays 'ok'"      {[$app2 do verdict R1] eq "ok"}

# the good 1N4007 board reviews clean
$app do command review
ok "1N4007 rectifier verdict ok"   {[$app do verdict D1] eq "ok"}

# ====================================================================
section "symbol standard toggle + delete"
# ====================================================================
$app do command togglestd
ok "toggle does not crash"         {1}
$app do select R1
$app do command delete
ok "delete removes from model"     {"R1" ni [$app do placed]}
ok "delete drops its wires"        {[apply {{app} {
    foreach w [$app do wires] { if {[string match "R1.*" [lindex $w 0]] || [string match "R1.*" [lindex $w 1]]} { return 0 } }
    return 1
}} $app]}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
