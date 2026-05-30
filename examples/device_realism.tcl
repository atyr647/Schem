# device_realism.tcl --
#
# The engine models real devices, not just ideal ones.  This tours the
# parasitics and dynamics that make a Schem circuit behave like a circuit on
# a real bench: source sag, wire drop, inductive-coil kickback, a Zener
# clamp, an inverse-time fuse, and a transformer -- with power and energy
# read off directly.
#
#   run with:  tclsh examples/device_realism.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

puts "Schem device realism\n"

# --- a real source sags under load, and bounds its own short current -----
set s [schem::new src]
$s add battery B -emf 12 -esr 0.5 ; $s add ground GND ; $s add resistor R -r 5
$s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
$s solve
puts [format "  Source ESR : 12 V, 0.5 ohm internal, 5 ohm load -> terminal %.2f V, %.2f A" \
    [$s probe B.pos] [$s current B]]
puts [format "               R dissipates %.2f W; the battery delivers %.2f W" \
    [$s power R] [$s power B]]
$s destroy

# --- a long thin wire is not a perfect conductor -------------------------
set s [schem::new wire]
$s add battery B -emf 12 ; $s add ground GND ; $s add resistor R -r 1
$s wire B.pos R.a -awg 22 -len 10 ; $s wire R.b GND.t -awg 22 -len 10 ; $s wire B.neg GND.t
$s solve
puts [format "\n  Wire drop  : 20 m of 22 AWG to a 1 ohm load -> %.2f A, %.2f V at the load" \
    [$s current R] [$s probe R.a]]
$s destroy

# --- an inductive relay coil kicks back; a flyback diode tames it --------
proc coilpeak {flyback} {
    set s [schem::new k]
    $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
    $s add switch SW -state closed
    $s add relay K -coil 100 -coilL 0.5 -pickup 0.08 -dropout 0.04
    $s wire B.pos SW.a ; $s wire SW.b K.c1 ; $s wire K.c2 GND.t
    if {$flyback} { $s add diode FW ; $s wire K.c1 FW.k ; $s wire FW.a K.c2 }
    set d [$s run -duration 0.02 -dt 5e-4 -record K.c1 -events {0.010 {open SW}}]
    set p 0.0 ; foreach v [dict get $d K.c1] { if {abs($v) > abs($p)} { set p $v } }
    $s destroy ; return $p
}
puts [format "\n  Coil kick  : interrupting an energised coil spikes to %.0f V" [coilpeak 0]]
puts [format "               ... a flyback diode across the coil clamps it to %.0f V" [coilpeak 1]]

# --- a Zener diode clamps a reverse voltage ------------------------------
set s [schem::new z]
$s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
$s add resistor R -r 1000 ; $s add diode Z -bv 5.1
$s wire B.pos R.a ; $s wire R.b Z.k ; $s wire Z.a GND.t
$s solve
puts [format "\n  Zener      : a 5.1 V Zener fed from 12 V through 1k clamps at %.2f V" \
    [$s voltage Z.k Z.a]]
$s destroy

# --- an inverse-time fuse: the bigger the overload, the faster it blows ---
proc blow {overR} {
    set s [schem::new f]
    $s add battery B -emf 12 ; $s add ground GND ; $s wire B.neg GND.t
    $s add fuse F -rating 1.0 -i2t 0.05 ; $s add resistor R -r $overR
    $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t
    set d [$s run -duration 1.0 -dt 5e-3 -record F]
    set tb -1
    foreach t [dict get $d t] i [dict get $d F] { if {$i < 0.01} { set tb $t ; break } }
    set i0 [lindex [dict get $d F] 0] ; $s destroy
    return [list $i0 $tb]
}
puts "\n  Fuse I2t   : 1 A fuse on an inverse-time curve"
foreach R {6 3 1.5} {
    lassign [blow $R] i tb
    puts [format "               %.0f A overload blows at t = %.0f ms" $i [expr {$tb*1000}]]
}

# --- a transformer steps voltage by its turns ratio ----------------------
set s [schem::new x]
$s add battery B -emf 10 ; $s add ground GND ; $s wire B.neg GND.t
$s add switch SW -state open
$s add transformer T -l1 1.0 -l2 0.25 -k 0.99
$s add resistor RP -r 1 ; $s add resistor RL -r 1000
$s wire B.pos SW.a ; $s wire SW.b RP.a ; $s wire RP.b T.p1 ; $s wire T.n1 GND.t
$s wire T.p2 RL.a ; $s wire RL.b GND.t ; $s wire T.n2 GND.t
set d [$s run -duration 0.01 -dt 2e-4 -record {T.p1 T.p2} -events {0.001 {close SW}}]
set v1 [lindex [dict get $d T.p1] end] ; set v2 [lindex [dict get $d T.p2] end]
puts [format "\n  Transformer: 2:1 step-down (L1=1, L2=0.25) -> primary %.2f V, secondary %.2f V (ratio %.2f)" \
    $v1 $v2 [expr {$v2/$v1}]]
$s destroy
puts ""
