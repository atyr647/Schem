#!/usr/bin/env tclsh
# test_io.tcl -- the indicator lamp, the Nixie tube and magnetic-core memory.
# Each case builds a small board, solves it, and asserts the physics: a lamp
# lights only when its current reaches the glow threshold, a Nixie shows the
# digit of whichever cathode is pulled low, and a core stores a bit by
# coincident current, reads it destructively through its sense line, ignores a
# half-select, and -- the whole point of core memory -- keeps its bit across a
# power cycle.  Run:  tclsh tests/test_io.tcl
set here [file dirname [info script]]
source [file join $here .. src schem.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} {
        incr ::T ; puts "ok   - $name"
    } else {
        incr ::F ; puts "FAIL - $name"
    }
}
proc approx {a b {tol 1e-6}} { expr {abs($a-$b) < $tol} }
proc section {t} { puts "\n# $t" }
set newS {::schem::Schematic new}

# ====================================================================
section "indicator lamp -- lights when current reaches the glow threshold"
# ====================================================================
# 12 V straight across a 240 ohm filament: 50 mA, well above a 10 mA glow.
set s [{*}$newS lamp1]
$s add battery B -emf 12
$s add lamp    L -r 240 -ion 0.01
$s add ground  G
$s wire B.pos L.a
$s wire L.b   G.t
$s wire B.neg G.t
$s solve
ok "lamp draws E/R"        {[approx [$s lampCurrent L] 0.05 1e-4]}
ok "lamp is lit"           {[$s lit L]}
ok "brightness ~ I/Ion"    {[approx [$s brightness L] 5.0 1e-2]}

# Same lamp behind a big series resistor: starved below the glow threshold.
set s [{*}$newS lamp2]
$s add battery B -emf 12
$s add resistor R -r 100000
$s add lamp    L -r 240 -ion 0.01
$s add ground  G
$s wire B.pos R.a
$s wire R.b   L.a
$s wire L.b   G.t
$s wire B.neg G.t
$s solve
ok "starved lamp is dark"  {![$s lit L]}

# ====================================================================
section "Nixie tube -- shows the digit of the cathode pulled low"
# ====================================================================
proc nixie_board {cathode} {
    set s [::schem::Schematic new nixie]
    $s add battery B -emf 170
    $s add nixie   N -r 47000 -ion 1e-4
    $s add ground  G
    $s wire B.pos N.a
    $s wire B.neg G.t
    $s wire N.$cathode G.t   ;# only this cathode has a return path
    $s solve
    return $s
}
ok "grounding k7 shows 7" {[[nixie_board k7] digit N] == 7}
ok "grounding k3 shows 3" {[[nixie_board k3] digit N] == 3}
ok "grounding k0 shows 0" {[[nixie_board k0] digit N] == 0}
# Nothing pulled low -> tube is dark (-1).
set s [::schem::Schematic new nixie_dark]
$s add battery B -emf 170
$s add nixie   N
$s add ground  G
$s wire B.pos N.a
$s wire B.neg G.t
$s solve
ok "no cathode -> dark (-1)" {[$s digit N] == -1}

# ====================================================================
section "magnetic core -- coincident-current write, destructive read"
# ====================================================================
# Two drive lines, each set up to carry ~0.6 A (a half-select); together they
# sum past the 1.0 A switching threshold, so only their coincidence flips the
# core.  A sense lamp on the sense winding catches the read pulse.
set s [{*}$newS core1]
$s add core    C  -iswitch 1.0 -rline 1e-3
$s add battery Bx -emf 6 ;  $s add resistor Rx -r 10
$s add battery By -emf 6 ;  $s add resistor Ry -r 10
$s add lamp    SL -r 240 -ion 0.01
$s add ground  G
$s wire Bx.pos Rx.a ; $s wire Rx.b C.xp ; $s wire C.xn G.t ; $s wire Bx.neg G.t
$s wire By.pos Ry.a ; $s wire Ry.b C.yp ; $s wire C.yn G.t ; $s wire By.neg G.t
$s wire C.s SL.a ; $s wire SL.b G.t

$s degauss
ok "core starts at 0"           {[$s coreBit C] == 0}

# Coincident set: both lines positive -> net ~1.2 A >= 1.0 -> store a 1.
$s solve
ok "coincident write sets 1"    {[$s coreBit C] == 1}
ok "no sense pulse on a write"  {![$s coreSensed C]}
ok "sense lamp dark while idle" {![$s lit SL]}

# Destructive read: reverse both lines -> net ~ -1.2 A -> flips 1 back to 0
# and fires the sense winding.
$s set Bx emf -6 ; $s set By emf -6
$s solve
ok "read flips the stored 1"    {[$s coreBit C] == 0}
ok "read fires the sense line"  {[$s coreSensed C]}
ok "sense lamp lit by read"     {[$s lit SL]}

# Reading a 0 is silent (nothing stored, no flip, no pulse).
$s solve
ok "reading a 0 is silent"      {![$s coreSensed C]}
ok "core still 0"               {[$s coreBit C] == 0}

# ====================================================================
section "magnetic core -- half-select does NOT switch"
# ====================================================================
$s set Bx emf 6 ; $s set By emf 6 ; $s solve
ok "re-set to 1"                {[$s coreBit C] == 1}
# Drive only the X line negative (a single half-select, ~ -0.6 A): below the
# -1.0 A threshold, so the core must hold its 1.
$s set By emf 0 ; $s set Bx emf -6 ; $s solve
ok "half-select holds the bit"  {[$s coreBit C] == 1}
ok "half-select is silent"      {![$s coreSensed C]}

# ====================================================================
section "magnetic core -- NON-VOLATILE across a power cycle"
# ====================================================================
$s set By emf 6 ; $s set Bx emf 6 ; $s solve   ;# store a 1
ok "stored 1 before power-off"  {[$s coreBit C] == 1}
$s powerReset                                   ;# cut and restore power
ok "core survives power cycle"  {[$s coreBit C] == 1}
$s degauss                                      ;# only a bulk erase clears it
ok "degauss wipes the core"     {[$s coreBit C] == 0}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
