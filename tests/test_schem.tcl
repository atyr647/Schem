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

test wire-resistance {a long gauged run drops real voltage (AWG ohms/m)} -setup {
    set s [schem::new t]
    $s add battery B -emf 12 ; $s add ground GND ; $s add resistor R -r 1
    # 10 m of 22 AWG (~0.529 ohm) in each leg; load is 1 ohm.
    $s wire B.pos R.a -awg 22 -len 10
    $s wire R.b GND.t -awg 22 -len 10
    $s wire B.neg GND.t
    $s solve
} -body {
    # I = 12 / (1 + 2*0.5292) ~ 5.83 A (not the ideal 12 A).
    approx [$s current R] [expr {12.0/(1.0 + 2*0.5292)}] 0.02
} -cleanup {$s destroy} -result ok

# ---- source realism: a battery's internal resistance ---------------------

test esr-voltage-sag {a real source sags under load by I*esr} -setup {
    set s [schem::new t]
    $s add battery B -emf 9 -esr 1.0
    $s add ground GND
    $s add resistor R -r 1000
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    # I = 9/(1000+1) A; terminal V = 9 - I*1 = 8.99101...
    approx [$s probe B.pos] [expr {9.0 - 9.0/1001.0}] 1e-4
} -cleanup {$s destroy} -result ok

test esr-bounds-short {internal resistance bounds the short-circuit current} -setup {
    set s [schem::new t]
    $s add battery B -emf 12 -esr 0.5
    $s add ground GND
    $s add resistor R -r 0.5         ;# near-dead short across the source
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    # I = 12/(0.5+0.5) = 12 A, finite -- not a singular matrix
    approx [$s current B] 12.0 1e-3
} -cleanup {$s destroy} -result ok

# ---- relay hysteresis: pick-up above, drop-out below ---------------------

test relay-hysteresis {a relay holds in between drop-out and pick-up} -setup {
    # Coil 100 ohm; pick-up 0.05 A (5 V), drop-out 0.02 A (2 V).  A weak
    # always-on drive sits the coil inside the band; a switchable strong
    # drive pushes it above pick-up.
    set s [schem::new t]
    $s add battery B -emf 12
    $s add ground GND ; $s wire B.neg GND.t
    $s add resistor RW -r 250         ;# weak: 12/(250+100)=0.0343A (in the band)
    $s add switch  HI -state open
    $s add resistor RH -r 50          ;# strong: parallels RW, pushes well over pick-up
    $s add relay K -coil 100 -pickup 0.05 -dropout 0.02
    $s wire B.pos RW.a ; $s wire RW.b K.c1
    $s wire B.pos HI.a ; $s wire HI.b RH.a ; $s wire RH.b K.c1
    $s wire K.c2 GND.t
} -body {
    $s open  HI ; $s solve ; set a [$s energized K]   ;# in the band from below -> out
    $s close HI ; $s solve ; set b [$s energized K]   ;# over pick-up -> comes in
    $s open  HI ; $s solve ; set c [$s energized K]   ;# back in the band -> holds
    list $a $b $c
} -cleanup {$s destroy} -result {0 1 1}

# ---- relay propagation delay (transient) ---------------------------------

test relay-delay {contacts move only after the operate delay elapses} -setup {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add switch IN -state open ; $s wire VCC.pos IN.a
    $s add relay K -coil 100 -pickup 0.05 -dropout 0.03 -delay 0.002
    $s wire IN.b K.c1 ; $s wire K.c2 GND.t
    $s wire VCC.pos K.com
    $s add resistor LD -r 10000 ; $s wire K.no LD.a ; $s wire LD.b GND.t
} -body {
    # IN closes at 1 ms; with a 2 ms operate delay the make contact is still
    # open at 2 ms and closed by 4 ms.
    set d [$s run -duration 0.006 -dt 5e-4 -record K.no -events {0.001 {close IN}}]
    set at {t {upvar 1 d d ; expr {[lindex [dict get $d K.no] [expr {int(round($t/5e-4))}]] > 6}}}
    list [apply $at 0.002] [apply $at 0.004]
} -cleanup {$s destroy} -result {0 1}

test relay-delay-glitch {a coil glitch shorter than the delay is ignored} -setup {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add switch IN -state open ; $s wire VCC.pos IN.a
    $s add relay K -coil 100 -pickup 0.05 -dropout 0.03 -delay 0.002
    $s wire IN.b K.c1 ; $s wire K.c2 GND.t
    $s wire VCC.pos K.com
    $s add resistor LD -r 10000 ; $s wire K.no LD.a ; $s wire LD.b GND.t
} -body {
    # A 1 ms pulse (< 2 ms operate time): the contact never closes.
    set d [$s run -duration 0.006 -dt 5e-4 -record K.no \
        -events {0.001 {close IN} 0.002 {open IN}}]
    set hi 0
    foreach v [dict get $d K.no] { if {$v > 6} { set hi 1 } }
    set hi
} -cleanup {$s destroy} -result 0

# ---- the Meter reads directional (signed) current -----------------------

test current-signed {signed current gives direction; magnitude is unchanged} -setup {
    set s [schem::new t]
    $s add battery B -emf 9 ; $s add ground GND
    $s add resistor R1 -r 1000 ; $s add resistor R2 -r 2000 ; $s add ammeter M
    $s wire B.pos R1.a ; $s wire R1.b M.a ; $s wire M.b R2.a
    $s wire R2.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    # Conventional current flows pos -> R1.a -> ... so it enters R1 at a (+)
    # and enters the meter at a (+); the battery's pos->neg branch current is
    # negative on discharge.  Magnitudes are all 3 mA.
    list [expr {[$s current R1 -signed] > 0}] \
         [expr {[$s current M  -signed] > 0}] \
         [expr {[$s current B  -signed] < 0}] \
         [approx [$s current R1] 0.003 1e-5]
} -cleanup {$s destroy} -result {1 1 1 ok}

# ---- continuity tester conducts through coils and forward diodes --------

test continuity-coil {a continuity path exists through a relay coil} -setup {
    set s [schem::new t]
    $s add ground GND ; $s add relay K
} -body {
    $s continuity K.c1 K.c2
} -cleanup {$s destroy} -result 1

test continuity-diode {a forward diode conducts, a reverse diode does not} -setup {
    set s [schem::new t]
    $s add ground GND ; $s add diode D
} -body {
    list [$s continuity D.a D.k] [$s continuity D.k D.a]
} -cleanup {$s destroy} -result {1 0}

# ---- a real high-current load is not mistaken for a short ----------------
test short-vs-load {a legitimate low-resistance load is not flagged as a short} -setup {
    set s [schem::new t]
    # A starter-motor-like load: 100 V, 0.01 ohm source, 0.05 ohm load -> ~1.7 kA.
    $s add battery B -emf 100 -esr 0.01
    $s add ground GND
    $s add resistor R -r 0.05
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    # High current, but the source sees a real 0.05 ohm -- not a short.
    list [expr {[$s current B] > 1000}] \
         [expr {"short" in [lmap f [$s faults] {dict get $f kind}]}]
} -cleanup {$s destroy} -result {1 0}

# ---- power and energy ----------------------------------------------------

test power-balance {dissipated power equals delivered power (I^2R)} -setup {
    set s [schem::new t]
    $s add battery B -emf 9 ; $s add ground GND ; $s add resistor R -r 1000
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    # R dissipates I^2 R = +81 mW; the source delivers the same (negative).
    list [approx [$s power R] 0.081 1e-4] \
         [approx [$s power B] -0.081 1e-4] \
         [approx [$s power R] [expr {-[$s power B]}] 1e-9]
} -cleanup {$s destroy} -result {ok ok ok}

test energy-capacitor {a charged capacitor stores 1/2 C V^2} -setup {
    set s [schem::new t]
    $s add battery B -emf 10 ; $s add ground GND ; $s wire B.neg GND.t
    $s add resistor R -r 100 ; $s add capacitor C -c 1e-3
    $s wire B.pos R.a ; $s wire R.b C.a ; $s wire C.b GND.t
    $s run -duration 2.0 -dt 0.01
} -body {
    # Charged to ~10 V: E = 0.5 * 1e-3 * 100 = 0.05 J.
    approx [$s energy C] 0.05 1e-3
} -cleanup {$s destroy} -result ok

# ---- device parasitics ---------------------------------------------------

test inductor-winding-r {at DC an inductor is its winding resistance} -setup {
    set s [schem::new t]
    $s add battery B -emf 10 ; $s add ground GND ; $s add inductor L -l 1e-3 -r 5
    $s wire B.pos L.a ; $s wire L.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    approx [$s current L] 2.0 1e-6
} -cleanup {$s destroy} -result ok

test capacitor-leakage {a charged capacitor self-discharges through rleak} -setup {
    set s [schem::new t]
    $s add ground GND ; $s add capacitor C -c 1e-3 -v0 10 -rleak 1000
    $s wire C.b GND.t
    set d [$s run -duration 3.0 -dt 0.05 -record C.a]
} -body {
    # RC = rleak*C = 1 s; after 3 s -> 10*e^-3 ~ 0.5 V (well below the start).
    expr {[lindex [dict get $d C.a] end] < 1.0}
} -cleanup {$s destroy} -result 1

test diode-series-r {series resistance limits current and raises the drop} -setup {
    set s [schem::new t]
    $s add battery B -emf 5 ; $s add ground GND ; $s wire B.neg GND.t
    $s add diode D -rs 10 ; $s add resistor R -r 1
    $s wire B.pos D.a ; $s wire D.k R.a ; $s wire R.b GND.t
    $s solve
} -body {
    # I ~ (5 - 0.7)/(1 + 10) ~ 0.39 A; the terminal drop is ~0.7 + I*10.
    list [expr {abs([$s current D] - 0.39) < 0.05}] \
         [expr {[$s voltage D.a D.k] > 4.0}]
} -cleanup {$s destroy} -result {1 1}

test diode-zener {reverse breakdown clamps the voltage near bv} -setup {
    set s [schem::new t]
    $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
    $s add resistor R -r 1000 ; $s add diode Z -bv 5.1
    $s wire B.pos R.a ; $s wire R.b Z.k ; $s wire Z.a GND.t
    $s solve
} -body {
    # Reverse-biased Zener clamps in the breakdown knee just above bv,
    # far below the 12 V it would reach without breakdown.
    set vz [$s voltage Z.k Z.a]
    expr {$vz > 5.0 && $vz < 6.5}
} -cleanup {$s destroy} -result 1

# ---- fuse inverse time-current (I^2t) ------------------------------------

test fuse-inverse-time {a bigger overload blows the fuse sooner} -setup {
    proc ::blowtime {overR} {
        set s [schem::new t]
        $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
        $s add fuse F -rating 1.0 -i2t 0.05 ; $s add resistor R -r $overR
        $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t
        set d [$s run -duration 1.0 -dt 5e-3 -record F]
        set tb 1.0
        foreach t [dict get $d t] i [dict get $d F] {
            if {$i < 0.01} { set tb $t ; break }
        }
        $s destroy
        return $tb
    }
} -body {
    # 2 A (2x rating) must take longer to blow than 4 A (4x rating).
    expr {[blowtime 6] > [blowtime 3]}
} -cleanup {rename ::blowtime {}} -result 1

test fuse-i2t-dc {a steady DC overcurrent still blows an i2t fuse} -setup {
    set s [schem::new t]
    $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
    $s add fuse F -rating 1.0 -i2t 0.05 ; $s add resistor R -r 3
    $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t
    $s solve
} -body {
    $s get F state
} -cleanup {$s destroy} -result blown

# ---- inductive relay coil: operate delay from L/R, and kickback ----------

test coil-ramp {an inductive coil's current ramps, so pick-up is delayed} -setup {
    set s [schem::new t]
    $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
    $s add switch SW -state closed
    # coil 100 ohm, L = 0.5 H -> tau = L/R = 5 ms; pick-up 0.08 A.
    $s add relay K -coil 100 -coilL 0.5 -pickup 0.08 -dropout 0.04
    $s wire B.pos SW.a ; $s wire SW.b K.c1 ; $s wire K.c2 GND.t
} -body {
    set d [$s run -duration 0.03 -dt 5e-4 -record K]
    set cur [dict get $d K]
    # Current rises monotonically toward 12/100 = 0.12 A; early it is well
    # below pick-up, late it is above.
    list [expr {[lindex $cur 2] < 0.08}] [expr {[lindex $cur end] > 0.10}]
} -cleanup {$s destroy} -result {1 1}

test coil-kickback {interrupting an inductive coil spikes; a flyback diode clamps it} -setup {
    proc ::mkcoil {flyback} {
        set s [schem::new t]
        $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
        $s add switch SW -state closed
        $s add relay K -coil 100 -coilL 0.5 -pickup 0.08 -dropout 0.04
        $s wire B.pos SW.a ; $s wire SW.b K.c1 ; $s wire K.c2 GND.t
        if {$flyback} { $s add diode FW ; $s wire K.c1 FW.k ; $s wire FW.a K.c2 }
        return $s
    }
} -body {
    set peak {{s} {
        set d [$s run -duration 0.02 -dt 5e-4 -record K.c1 -events {0.010 {open SW}}]
        set p 0.0 ; foreach v [dict get $d K.c1] { if {abs($v) > abs($p)} { set p $v } }
        return $p
    }}
    set bare  [mkcoil 0] ; set pbare  [apply $peak $bare]  ; $bare destroy
    set clamp [mkcoil 1] ; set pclamp [apply $peak $clamp] ; $clamp destroy
    # The bare coil spikes far past the 12 V supply; the flyback diode holds
    # the node near the rail.
    list [expr {abs($pbare) > 50.0}] [expr {abs($pclamp) < 15.0}]
} -cleanup {rename ::mkcoil {}} -result {1 1}

# ---- transformer (mutual inductance) -------------------------------------

test transformer-ratio {a 2:1 transformer steps voltage by the turns ratio} -setup {
    set s [schem::new t]
    $s add battery B -emf 10 ; $s add ground GND ; $s wire B.neg GND.t
    $s add switch SW -state open
    # L1=1, L2=0.25 -> turns ratio sqrt(L2/L1) = 0.5 (step-down 2:1).
    $s add transformer T -l1 1.0 -l2 0.25 -k 0.99
    $s add resistor RP -r 1 ; $s add resistor RL -r 1000
    $s wire B.pos SW.a ; $s wire SW.b RP.a ; $s wire RP.b T.p1 ; $s wire T.n1 GND.t
    $s wire T.p2 RL.a ; $s wire RL.b GND.t ; $s wire T.n2 GND.t
    set d [$s run -duration 0.01 -dt 2e-4 -record {T.p1 T.p2} -events {0.001 {close SW}}]
} -body {
    # Once the primary is energised, V2/V1 ~ k*sqrt(L2/L1) = 0.495.
    set v1 [lindex [dict get $d T.p1] end]
    set v2 [lindex [dict get $d T.p2] end]
    expr {abs($v2/$v1 - 0.495) < 0.02}
} -cleanup {$s destroy} -result 1

# ---- memory (RAM): clocked write, persistent read ------------------------

test memory-pins {a memory's terminals scale with its address/data width} -setup {
    set s [schem::new m] ; $s add memory M -abits 3 -dbits 4
} -body {
    # 3 address + 4 data-in + 4 data-out + WE + CLK + GND = 14 pins.
    set t [$s terminals M]
    list [llength $t] [expr {"A2" in $t}] [expr {"DI3" in $t}] [expr {"DO3" in $t}] [expr {"WE" in $t}]
} -cleanup {$s destroy} -result {14 1 1 1 1}

test memory-fresh-reads-zero {a powered-up memory drives all data-out lines low} -setup {
    set s [schem::new m]
    $s add battery B -emf 12 ; $s add ground G ; $s add memory M -abits 2 -dbits 2
    $s wire B.neg G.t ; $s wire M.GND G.t ; $s wire B.pos M.A0
    $s solve
} -body {
    list [format %.2f [$s probe M.DO0]] [format %.2f [$s probe M.DO1]]
} -cleanup {$s destroy} -result {0.00 0.00}

test memory-write-read {a clocked write seals a word in; it reads back later} -setup {
    set s [schem::new m]
    $s add battery B -emf 12 ; $s add ground G ; $s add memory M -abits 2 -dbits 2
    $s add switch SW -state open
    $s wire B.neg G.t ; $s wire M.GND G.t
    $s wire B.pos M.DI0 ; $s wire B.pos M.WE      ;# write the value 0b01 to addr 0
    $s wire B.pos SW.a ; $s wire SW.b M.CLK       ;# SW pulses the clock
} -body {
    # Pulse the clock once (rising edge writes); the word then persists, and
    # data-out reads it back one step later and holds it after CLK falls.
    set r [$s run -duration 0.008 -dt 0.001 -record {M.DO0 M.DO1} \
            -events {0.002 {close SW} 0.004 {open SW}}]
    set do0 [dict get $r M.DO0] ; set do1 [dict get $r M.DO1]
    # before the edge: low; after it (and after CLK falls): DO0 high, DO1 low.
    list [format %.1f [lindex $do0 1]] [format %.1f [lindex $do0 end]] [format %.1f [lindex $do1 end]]
} -cleanup {$s destroy} -result {0.0 12.0 0.0}

cleanupTests
