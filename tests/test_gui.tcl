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

# ====================================================================
section "save / load round-trip"
# ====================================================================
set app3 [::schem::gui::App new [::schem::new rt]]
set s3 [$app3 schematic]
$app3 do pick-primitive battery ; $app3 do click 200 200
$app3 do pick-part 1N4007 ;       $app3 do click 400 200
$app3 do pick-primitive resistor ;$app3 do click 600 200
$app3 do pick-primitive ground ;  $app3 do click 400 400
$app3 do wire BT1.pos D1.a ; $app3 do wire D1.k R1.a
$app3 do wire R1.b GND1.t ; $app3 do wire BT1.neg GND1.t
set tmp [file join [file dirname [info script]] guitmp[pid].schem]
$app3 do save-to $tmp
ok "save writes a file"            {[file exists $tmp] && [file size $tmp] > 0}
set app4 [::schem::gui::App new [::schem::load $tmp]]
ok "load restores all parts"       {[llength [$app4 do placed]] == 4}
ok "load restores all wires"       {[llength [$app4 do wires]] == 4}
ok "part identity recovered"       {[::schem::parts::idOf [$app4 schematic] D1] eq "1N4007"}
file delete $tmp

# identify a part purely from its model params (no session tag)
set sx [::schem::new x]
::schem::parts::place $sx Dx 1N5819
set sy [::schem::new y]   ;# fresh schematic, never tagged
$sy add diode Dy -is 3.2e-5 -n 1.05 -rs 0.07 -bv 40
ok "identify matches by params"    {[::schem::parts::identify $sy Dy] eq "1N5819"}
ok "non-matching params -> none"   {[apply {{} {
    set s [::schem::new z] ; $s add diode D -is 1e-14 -n 1 -rs 0 -bv 5
    expr {[::schem::parts::identify $s D] eq ""}
}}]}

# ====================================================================
section "compile / validate / netlist / transient / zoom"
# ====================================================================
set app5 [::schem::gui::App new [::schem::new feat]]
set s5 [$app5 schematic]
$app5 do pick-primitive battery ;  $app5 do click 200 200
$app5 do pick-primitive resistor ; $app5 do click 400 200
$app5 do pick-primitive ground ;   $app5 do click 200 360
$app5 do wire BT1.pos R1.a ; $app5 do wire R1.b GND1.t ; $app5 do wire BT1.neg GND1.t

# compile down to Zig
set zig [$app5 do compile]
ok "compile emits Zig"             {[string match "*@import(\"std\")*" $zig]}
ok "compiled Zig has a main"       {[regexp {fn\s+main} $zig]}
ok "compiled Zig is substantial"   {[llength [split $zig \n]] > 40}

# validate (design-rule check)
ok "validate produces a report"    {[string length [$app5 do validate-text]] > 0}

# netlist
ok "netlist names nodes"           {[string match "*nodes*" [$app5 do netlist-text]]}

# transient run on an AC source
set app6 [::schem::gui::App new [::schem::new tr]]
set s6 [$app6 schematic]
$app6 do pick-primitive vsource ;  $app6 do click 200 200
$app6 do pick-primitive resistor ; $app6 do click 400 200
$app6 do pick-primitive ground ;   $app6 do click 200 360
$s6 set J1 vac 10 ; $s6 set J1 freq 100
$app6 do wire J1.pos R1.a ; $app6 do wire R1.b GND1.t ; $app6 do wire J1.neg GND1.t
set res [$app6 do run-transient 0.02 1e-4 R1.a]
ok "transient returns a time axis"  {[llength [dict get $res t]] > 10}
ok "transient records the node"     {[dict exists $res R1.a]}
set vs [dict get $res R1.a]
ok "AC trace swings positive+neg"   {[lindex [lsort -real $vs] end] > 1 && [lindex [lsort -real $vs] 0] < -1}

# zoom
ok "zoom starts at 1.0"            {abs([$app5 do zoom]-1.0) < 1e-9}
$app5 do command zoomin
ok "zoom-in raises the factor"     {[$app5 do zoom] > 1.0}
$app5 do command zoomreset
ok "zoom-reset returns to 1.0"     {abs([$app5 do zoom]-1.0) < 1e-9}
$app5 do command fitall
ok "fit picks a sane zoom"         {[$app5 do zoom] > 0.3 && [$app5 do zoom] <= 3.0}

# ====================================================================
section "AC sweep, current/power probe, switch operation"
# ====================================================================
# RC low-pass: verify the GUI's AC path is electrically correct.
set app7 [::schem::gui::App new [::schem::new rc]]
set s7 [$app7 schematic]
$app7 do pick-primitive battery ;   $app7 do click 200 200
$app7 do pick-primitive resistor ;  $app7 do click 400 200
$app7 do pick-primitive capacitor ; $app7 do click 520 360
$app7 do pick-primitive ground ;    $app7 do click 200 360
$s7 set R1 r 1600 ; $s7 set C1 c 1e-7
$app7 do wire BT1.pos R1.a ; $app7 do wire R1.b C1.a ; $app7 do wire C1.b GND1.t ; $app7 do wire BT1.neg GND1.t
# corner ~995 Hz: passband ~0 dB, -3 dB at corner, -20 dB/dec stopband
ok "AC passband near 0 dB"     {abs([$app7 do ac-mag C1.a 100]) < 0.2}
ok "AC -3 dB at the corner"    {abs([$app7 do ac-mag C1.a 995] - -3.01) < 0.2}
ok "AC stopband ~ -20 dB/dec"  {abs([$app7 do ac-mag C1.a 10000] - -20.0) < 0.5}

# current / power available after a solve
$app7 do command solve
ok "current is readable"       {![catch {[$app7 schematic] current R1}]}
ok "power is readable"         {![catch {[$app7 schematic] power R1}]}

# switch operation via double-click toggles state and forces a re-solve
set app8 [::schem::gui::App new [::schem::new sw]]
set s8 [$app8 schematic]
$app8 do pick-primitive battery ; $app8 do click 200 200
$app8 do pick-primitive switch ;  $app8 do click 400 200
$app8 do pick-primitive resistor ;$app8 do click 600 200
$app8 do pick-primitive ground ;  $app8 do click 200 360
$app8 do wire BT1.pos SW1.a ; $app8 do wire SW1.b R1.a ; $app8 do wire R1.b GND1.t ; $app8 do wire BT1.neg GND1.t
ok "switch starts open"        {[$app8 do stateof SW1] eq "open"}
$app8 do dblclick 400 200
ok "double-click closes it"    {[$app8 do stateof SW1] eq "closed"}
$app8 do dblclick 400 200
ok "double-click opens again"  {[$app8 do stateof SW1] eq "open"}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
