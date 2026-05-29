# test_schem.tcl --
#
# Regression suite for the Schem electrical interpreter.  Every test
# checks that the engine obeys a fundamental rule of electricity against a
# value computed by hand from circuit theory.
#
#   tclsh tests/test_schem.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

# approx -- assert |a-b| <= tol, returning a readable message on failure.
proc approx {a b {tol 1e-6}} {
    if {abs($a-$b) <= $tol} { return ok }
    return "got $a, expected $b (tol $tol)"
}

# ---- linear algebra core ------------------------------------------------

test la-1 {Gaussian elimination solves a 2x2 system} -body {
    approx [lindex [::schem::la::solve {{2 1} {1 3}} {3 5}] 0] 0.8
} -result ok

test la-2 {integer matrices are not subject to integer division} -body {
    approx [lindex [::schem::la::solve {{2 1} {1 3}} {3 5}] 1] 1.4
} -result ok

test la-3 {singular systems are rejected} -body {
    catch {::schem::la::solve {{1 1} {1 1}} {2 2}} e o
    lrange [dict get $o -errorcode] 0 1
} -result {SCHEM SINGULAR}

# ---- Ohm's law ----------------------------------------------------------

test ohm-current {9V across 1k draws 9mA (Ohm)} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add ground GND
    $s add resistor R -r 1000
    $s wire B.pos R.a ; $s wire R.b B.neg ; $s wire B.neg GND.t
    $s solve
} -body { approx [$s current R] 0.009 } -cleanup {$s destroy} -result ok

# ---- Kirchhoff's voltage law (series) -----------------------------------

test kvl-divider {voltage divider 1k/2k from 9V gives 6V (KVL)} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add ground GND
    $s add resistor R1 -r 1000
    $s add resistor R2 -r 2000
    $s wire B.pos R1.a ; $s wire R1.b R2.a ; $s wire R2.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body { approx [$s probe R1.b] 6.0 } -cleanup {$s destroy} -result ok

test kvl-series-current {two equal series resistors share the loop current} -setup {
    set s [schem::new t]
    $s add battery B -emf 10
    $s add ground GND
    $s add resistor R1 -r 1000
    $s add resistor R2 -r 1000
    $s wire B.pos R1.a ; $s wire R1.b R2.a ; $s wire R2.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body { approx [$s current R1] [$s current R2] } -cleanup {$s destroy} -result ok

# ---- Kirchhoff's current law (parallel) ---------------------------------

test kcl-parallel {parallel branch currents sum at the source node} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add ground GND
    $s add resistor R1 -r 1000
    $s add resistor R2 -r 3000
    $s wire B.pos R1.a ; $s wire B.pos R2.a
    $s wire R1.b GND.t ; $s wire R2.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    approx [$s current B] [expr {[$s current R1] + [$s current R2]}]
} -cleanup {$s destroy} -result ok

# ---- continuity ---------------------------------------------------------

test continuity-open {an open switch breaks continuity -> no current} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add ground GND
    $s add switch SW
    $s add resistor R -r 1000
    $s wire B.pos SW.a ; $s wire SW.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    list [$s continuity B.pos R.a] [approx [$s current R] 0.0 1e-6]
} -cleanup {$s destroy} -result {0 ok}

test continuity-closed {closing the switch restores continuity and current} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add ground GND
    $s add switch SW
    $s add resistor R -r 1000
    $s wire B.pos SW.a ; $s wire SW.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s close SW
    $s solve
} -body {
    list [$s continuity B.pos R.a] [approx [$s current R] 0.009]
} -cleanup {$s destroy} -result {1 ok}

# ---- relay (conditional routing emerges, no "if") -----------------------

test relay-off {de-energised relay leaves its NO load unpowered} -setup {
    set s [schem::new t]
    $s add battery BC -emf 9
    $s add battery BL -emf 12
    $s add ground GND
    $s add button BTN
    $s add relay K -coil 100 -pickup 0.02
    $s add resistor LOAD -r 1000
    $s wire BC.pos BTN.a ; $s wire BTN.b K.c1 ; $s wire K.c2 GND.t ; $s wire BC.neg GND.t
    $s wire BL.pos K.com ; $s wire K.no LOAD.a ; $s wire LOAD.b GND.t ; $s wire BL.neg GND.t
    $s solve
} -body { list [$s energized K] [approx [$s current LOAD] 0.0 1e-6] } \
  -cleanup {$s destroy} -result {0 ok}

test relay-on {pressing the button energises the coil and powers the load} -setup {
    set s [schem::new t]
    $s add battery BC -emf 9
    $s add battery BL -emf 12
    $s add ground GND
    $s add button BTN
    $s add relay K -coil 100 -pickup 0.02
    $s add resistor LOAD -r 1000
    $s wire BC.pos BTN.a ; $s wire BTN.b K.c1 ; $s wire K.c2 GND.t ; $s wire BC.neg GND.t
    $s wire BL.pos K.com ; $s wire K.no LOAD.a ; $s wire LOAD.b GND.t ; $s wire BL.neg GND.t
    $s press BTN
    $s solve
} -body { list [$s energized K] [approx [$s current LOAD] 0.012] } \
  -cleanup {$s destroy} -result {1 ok}

# ---- diode (one-way flow) ----------------------------------------------

test diode-forward {forward-biased diode clamps near 0.6-0.75V} -setup {
    set s [schem::new t]
    $s add battery B -emf 5
    $s add ground GND
    $s add resistor R -r 1000
    $s add diode D
    $s wire B.pos R.a ; $s wire R.b D.a ; $s wire D.k GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    set vd [$s voltage D.a D.k]
    expr {$vd > 0.55 && $vd < 0.8}
} -cleanup {$s destroy} -result 1

test diode-reverse {reverse-biased diode blocks current} -setup {
    set s [schem::new t]
    $s add battery B -emf -5
    $s add ground GND
    $s add resistor R -r 1000
    $s add diode D
    $s wire B.pos R.a ; $s wire R.b D.a ; $s wire D.k GND.t ; $s wire B.neg GND.t
    $s solve
} -body { expr {[$s current R] < 1e-6} } -cleanup {$s destroy} -result 1

# ---- fuse (irreversible fault) ------------------------------------------

test fuse-blow {an over-current fuse blows and opens the circuit} -setup {
    set s [schem::new t]
    $s add battery B -emf 10
    $s add ground GND
    $s add fuse F -rating 0.5
    $s add resistor R -r 10
    $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    list [$s get F state] [approx [$s current R] 0.0 1e-6] \
         [expr {[llength [$s faults]] >= 1}]
} -cleanup {$s destroy} -result {blown ok 1}

test fuse-irreversible {a blown fuse cannot be reset} -setup {
    set s [schem::new t]
    $s add fuse F -rating 0.5
    $s set F state blown
} -body { catch {$s reset F} } -cleanup {$s destroy} -result 1

# ---- breaker (resettable limit) -----------------------------------------

test breaker-trip-reset {breaker trips on overload and can be reset} -setup {
    set s [schem::new t]
    $s add battery B -emf 10
    $s add ground GND
    $s add breaker CB -rating 0.5
    $s add resistor R -r 10
    $s wire B.pos CB.a ; $s wire CB.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    set tripped [$s get CB state]
    $s reset CB ; $s set R r 100 ; $s solve
    list $tripped [$s get CB state] [approx [$s current R] 0.1]
} -cleanup {$s destroy} -result {tripped closed ok}

# ---- short circuit (fundamental fault) ----------------------------------

test short-circuit {an ideal short across a source is reported as a fault} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add ground GND
    $s add switch SW -state closed
    $s wire B.pos SW.a ; $s wire SW.b B.neg ; $s wire B.neg GND.t
    $s solve
} -body {
    set f [$s faults]
    expr {[llength $f] == 1 && [dict get [lindex $f 0] kind] eq "short"}
} -cleanup {$s destroy} -result 1

test no-ground {a schematic with no ground reference is rejected} -setup {
    set s [schem::new t]
    $s add battery B -emf 9
    $s add resistor R -r 1000
    $s wire B.pos R.a ; $s wire R.b B.neg
} -body {
    catch {$s solve} e o
    lrange [dict get $o -errorcode] 0 1
} -cleanup {$s destroy} -result {SCHEM NOGROUND}

# ---- capacitor transient (RC charging) ----------------------------------

test rc-charge {RC charges along V(t)=E(1-e^{-t/RC})} -setup {
    set s [schem::new t]
    $s add battery B -emf 10
    $s add ground GND
    $s add resistor R -r 1000
    $s add capacitor C -c 1e-3 -v0 0
    $s wire B.pos R.a ; $s wire R.b C.a ; $s wire C.b GND.t ; $s wire B.neg GND.t
    set d [$s run -duration 1.0 -dt 0.0005 -record C.a]
} -body {
    # value at t≈1.0 (=1 time constant) should be ~6.32V
    set v [lindex [dict get $d C.a] end]
    approx $v 6.32 0.05
} -cleanup {$s destroy} -result ok

# ---- inductor transient (RL current rise) -------------------------------

test rl-rise {RL current rises toward V/R along I(t)=I_max(1-e^{-tR/L})} -setup {
    set s [schem::new t]
    $s add battery B -emf 10
    $s add ground GND
    $s add resistor R -r 10
    $s add inductor L -l 10 -i0 0
    $s wire B.pos R.a ; $s wire R.b L.a ; $s wire L.b GND.t ; $s wire B.neg GND.t
    # tau = L/R = 1s; at t=1s I ~ (10/10)*0.632 = 0.632A
    set d [$s run -duration 1.0 -dt 0.0005 -record L]
} -body {
    approx [lindex [dict get $d L] end] 0.632 0.02
} -cleanup {$s destroy} -result ok

# ---- relay oscillator (emergent timing) ---------------------------------

test relay-oscillator {a relay wired through its own NC contact oscillates} -setup {
    set s [schem::new t]
    $s add battery B -emf 12
    $s add ground GND
    $s add relay K -coil 100 -pickup 0.05
    $s wire B.pos K.com ; $s wire K.nc K.c1 ; $s wire K.c2 GND.t ; $s wire B.neg GND.t
    set d [$s run -duration 0.02 -dt 0.001 -record K.c1]
} -body {
    set prev "" ; set trans 0
    foreach v [dict get $d K.c1] {
        set hi [expr {$v > 1}]
        if {$prev ne "" && $hi != $prev} { incr trans }
        set prev $hi
    }
    expr {$trans > 2}
} -cleanup {$s destroy} -result 1

# ---- hierarchy (Component -> Circuit -> Panel -> Grid) -------------------

test hierarchy-flatten {a circuit embedded in a panel in a grid solves flat} -setup {
    proc ::mkdiv {} {
        set c [schem::circuit divider]
        $c add resistor R1 -r 1000
        $c add resistor R2 -r 1000
        $c wire R1.b R2.a
        $c expose IN R1.a ; $c expose OUT R1.b ; $c expose GND R2.b
        return $c
    }
    set panel [schem::panel P]
    $panel add battery B -emf 12
    $panel add ground GND
    set m [$panel instantiate [mkdiv] U1]
    $panel wire B.pos [dict get $m IN]
    $panel wire [dict get $m GND] GND.t
    $panel wire B.neg GND.t
    set grid [schem::grid G]
    $grid instantiate $panel BANK
    $grid solve
} -body {
    approx [$grid probe BANK/U1/R1.b] 6.0
} -cleanup {$panel destroy ; $grid destroy ; rename ::mkdiv {}} -result ok

# ---- wire ampacity overload ---------------------------------------------

test wire-overload {a gauged wire carrying more than its ampacity faults} -setup {
    set s [schem::new t]
    $s add battery B -emf 10
    $s add ground GND
    $s add resistor R -r 1
    # 22 AWG ampacity ~7A; 10A here -> overload
    $s wire B.pos R.a -awg 22
    $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    set kinds [lmap f [$s faults] {dict get $f kind}]
    expr {"wire-overload" in $kinds}
} -cleanup {$s destroy} -result 1

cleanupTests
