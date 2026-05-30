# test_ac.tcl --
#
# AC (frequency-domain) analysis tests.  Covers the acsweep method, the
# complex MNA solver, and the known analytical results for simple RC / RL / RLC
# circuits.
#
#   tclsh tests/test_ac.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

# ---- helpers -------------------------------------------------------

# close? -- true if two values are within tol of each other.
proc close? {a b {tol 0.1}} { expr {abs($a - $b) <= $tol} }

# ====================================================================
#  RC low-pass filter
#
#  VIN ---R--- Vout ---C--- GND
#
#  Analytical: |Vout/Vin| = 1 / sqrt(1 + (2πf RC)²)
#  -3 dB frequency: f3 = 1 / (2π R C)
# ====================================================================

test rc-lowpass-pass {RC low-pass: well below -3dB frequency is near 0 dB} -setup {
    set s [schem::new rc_lp]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add resistor R -r 1000
    $s add capacitor C -c 1e-6
    $s wire VIN.neg GND.t
    $s wire VIN.pos R.a
    $s wire R.b C.a
    $s wire C.b GND.t
} -body {
    # f3 = 1/(2π×1000×1e-6) ≈ 159 Hz; at 1 Hz we should be within 0.001 dB of 0 dB
    set sw [$s acsweep {1.0}]
    set vout [$s acnode $sw 1.0 C.a]
    close? [$s acmag $vout] 0.0 0.01
} -cleanup {$s destroy} -result 1

test rc-lowpass-3db {RC low-pass: -3 dB at f = 1/(2π R C)} -setup {
    set s [schem::new rc_3db]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add resistor R -r 1000
    $s add capacitor C -c 1e-6
    $s wire VIN.neg GND.t
    $s wire VIN.pos R.a
    $s wire R.b C.a
    $s wire C.b GND.t
} -body {
    # f3 ≈ 159.155 Hz
    set f3 [expr {1.0 / (2 * 3.14159265 * 1000 * 1e-6)}]
    set sw [$s acsweep [list $f3]]
    set vout [$s acnode $sw $f3 C.a]
    # magnitude at -3dB should be -3.0 dB ± 0.1 dB
    close? [$s acmag $vout] -3.0103 0.1
} -cleanup {$s destroy} -result 1

test rc-lowpass-stopband {RC low-pass: well above corner attenuates at -20 dB/decade} -setup {
    set s [schem::new rc_stop]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add resistor R -r 1000
    $s add capacitor C -c 1e-6
    $s wire VIN.neg GND.t
    $s wire VIN.pos R.a
    $s wire R.b C.a
    $s wire C.b GND.t
} -body {
    set f3 [expr {1.0 / (2 * 3.14159265 * 1000 * 1e-6)}]
    # 10× above corner: should be ≈ -20 dB below the corner (i.e. ≈ -23 dB total)
    set sw [$s acsweep [list [expr {$f3 * 10}]]]
    set vout [$s acnode $sw [expr {$f3 * 10}] C.a]
    close? [$s acmag $vout] -20.04 0.5
} -cleanup {$s destroy} -result 1

test rc-phase-at-corner {RC low-pass: phase at -3 dB corner is -45 degrees} -setup {
    set s [schem::new rc_ph]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add resistor R -r 1000
    $s add capacitor C -c 1e-6
    $s wire VIN.neg GND.t
    $s wire VIN.pos R.a
    $s wire R.b C.a
    $s wire C.b GND.t
} -body {
    set f3 [expr {1.0 / (2 * 3.14159265 * 1000 * 1e-6)}]
    set sw [$s acsweep [list $f3]]
    set vout [$s acnode $sw $f3 C.a]
    close? [$s acphase $vout] -45.0 1.0
} -cleanup {$s destroy} -result 1

# ====================================================================
#  RL circuit (high-pass behaviour: inductor in series, resistor to GND)
#
#  VIN ---L--- Vout ---R--- GND
#
#  Analytical: |Vout/Vin| = (2πf L/R) / sqrt(1 + (2πf L/R)²)
#  -3 dB frequency: f3 = R/(2π L)
# ====================================================================

test rl-highpass-3db {RL high-pass: -3 dB at f = R/(2π L)} -setup {
    set s [schem::new rl_hp]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add inductor L -l 0.1
    $s add resistor R -r 1000
    $s wire VIN.neg GND.t
    $s wire VIN.pos L.a
    $s wire L.b R.a
    $s wire R.b GND.t
} -body {
    # f3 = 1000/(2π×0.1) ≈ 1591.5 Hz
    set f3 [expr {1000.0 / (2 * 3.14159265 * 0.1)}]
    set sw [$s acsweep [list $f3]]
    set vout [$s acnode $sw $f3 R.a]
    close? [$s acmag $vout] -3.0103 0.15
} -cleanup {$s destroy} -result 1

# ====================================================================
#  RLC resonator
#
#  VIN --- R --- L --- C --- GND,  measure across C
#
#  Series RLC resonance at f0 = 1/(2π sqrt(LC))
#  At resonance: Vc/Vin = 1/(j ω0 RC) -> magnitude = 1/(ω0 RC)
# ====================================================================

test rlc-resonance {RLC: peak near resonant frequency} -setup {
    # R=10Ω, L=10mH, C=10µF -> f0 = 1/(2π sqrt(0.01*10e-6)) ≈ 503 Hz
    set s [schem::new rlc]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add resistor R -r 10
    $s add inductor L -l 0.01
    $s add capacitor C -c 10e-6
    $s wire VIN.neg GND.t
    $s wire VIN.pos R.a
    $s wire R.b L.a
    $s wire L.b C.a
    $s wire C.b GND.t
} -body {
    set f0 [expr {1.0 / (2 * 3.14159265 * sqrt(0.01 * 10e-6))}]
    set sw [$s acsweep [list $f0]]
    set vout [$s acnode $sw $f0 C.a]
    # Q = sqrt(L/C)/R = sqrt(0.01/10e-6)/10 ≈ 3.16; gain across C = Q ≈ 10 dB
    # acmag should be > 9 dB (voltage magnification at resonance)
    expr {[$s acmag $vout] > 9.0}
} -cleanup {$s destroy} -result 1

# ====================================================================
#  Voltage divider: two equal resistors -> 0.5 amplitude at mid-point
#  (purely resistive, should behave the same at all frequencies)
# ====================================================================

test ac-divider {Voltage divider: flat -6 dB across frequency} -setup {
    set s [schem::new acdiv]
    $s add battery VIN -emf 1
    $s add ground GND
    $s add resistor R1 -r 1000
    $s add resistor R2 -r 1000
    $s wire VIN.neg GND.t
    $s wire VIN.pos R1.a
    $s wire R1.b R2.a
    $s wire R2.b GND.t
} -body {
    set sw [$s acsweep {1.0 100.0 10000.0}]
    set ok 1
    foreach f {1.0 100.0 10000.0} {
        set v [$s acnode $sw $f R2.a]
        if {![close? [$s acmag $v] -6.0206 0.1]} { set ok 0 }
    }
    set ok
} -cleanup {$s destroy} -result 1

cleanupTests
