# test_cir.tcl --
#
# The Circuit IR (the lowered, backend-agnostic compile target) and the
# backend interface.  Checks that compiling a schematic classifies every
# element by electrical role with the right derived quantities, that the IR
# carries enough to reproduce the solve (a reference DC backend matches the
# engine), and that the Zig emitter produces the expected program and refuses
# the element classes it does not yet support.
#
#   tclsh tests/test_cir.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic.tcl]

# elem -- find the element named `name` in a CIR.
proc elem {cir name} {
    foreach e [dict get $cir elements] { if {[dict get $e name] eq $name} { return $e } }
    return ""
}

# ---- the IR classifies elements by electrical role -----------------------

test cir-roles {each element is lowered to its electrical role + derived values} -setup {
    set s [schem::new mix]
    $s add battery B -emf 12 -esr 0.5 ; $s add ground GND ; $s wire B.neg GND.t
    $s add resistor R -r 250
    $s add relay K ; $s add diode D ; $s add capacitor C -c 1e-5 ; $s add inductor L -l 1e-3 -r 2
    $s add fuse F -rating 3 ; $s add ammeter M
    $s wire B.pos R.a ; $s wire R.b GND.t
    set ir [$s compile]
} -body {
    list [dict get [elem $ir B] class] \
         [dict get [elem $ir B] rs] \
         [dict get [elem $ir R] class] [dict get [elem $ir R] g] \
         [dict get [elem $ir K] class] \
         [dict get [elem $ir D] class] \
         [dict get [elem $ir C] class] \
         [dict get [elem $ir L] class] \
         [dict get [elem $ir F] class] \
         [dict get [elem $ir M] class]
} -cleanup {$s destroy} -result {source 0.5 conductance 0.004 relay nonlinear reactive reactive protective meter}

test cir-relay-control {a relay carries its coil R/L and pick-up/drop-out/delay/contact} -setup {
    set s [schem::new r]
    $s add ground GND ; $s add relay K -coil 200 -coilL 0.5 -pickup 0.03 -dropout 0.01 -delay 0.002
    set ir [$s compile]
} -body {
    set k [elem $ir K]
    list [dict get $k coil r] [dict get $k coil l] [dict get $k coil g] \
         [dict get $k pickup] [dict get $k dropout] [dict get $k delay] \
         [dict keys [dict get $k contact nodes]]
} -cleanup {$s destroy} -result {200.0 0.5 0.005 0.03 0.01 0.002 {com no nc}}

test cir-analysis-flags {the IR flags reactive / nonlinear / stateful character} -setup {
    set s [schem::new f] ; $s add battery B ; $s add ground GND ; $s add resistor R
    $s wire B.pos R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    set lin [$s compile]
    $s add diode D ; $s add capacitor C
    set rich [$s compile]
} -body {
    list [dict get $lin analysis] [dict get $rich analysis]
} -cleanup {$s destroy} -result {{reactive 0 nonlinear 0 stateful 0} {reactive 1 nonlinear 1 stateful 0}}

test cir-ground-folded {ground/bus/junction are folded into nodes, not elements} -setup {
    set s [schem::new g]
    $s add battery B ; $s add ground GND ; $s add junction J ; $s add resistor R
    $s wire B.pos J.t ; $s wire J.t R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    set ir [$s compile]
} -body {
    lsort [lmap e [dict get $ir elements] {dict get $e name}]
} -cleanup {$s destroy} -result {B R}

# ---- the IR is sufficient to reproduce the solve (reference backend) ------

test cir-dcref-matches-engine {a DC solve driven only by the IR matches the engine} -setup {
    set s [schem::new d]
    $s add battery B -emf 9 -esr 1.0 ; $s add ground GND
    $s add resistor R1 -r 1000 ; $s add resistor R2 -r 2000 ; $s add ammeter M
    $s wire B.pos M.a ; $s wire M.b R1.a ; $s wire R1.b R2.a ; $s wire R2.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    set v [schem::backend::dcref [$s compile]]
    set ok 1
    set ir [$s compile]
    dict for {nid terms} [dict get $ir nodes map] {
        if {$nid == 0} continue
        if {abs([dict get $v $nid] - [$s probe [lindex $terms 0]]) > 1e-4} { set ok 0 }
    }
    set ok
} -cleanup {$s destroy} -result 1

test cir-dcref-switch {the IR captures switch state (open vs closed)} -setup {
    set s [schem::new sw]
    $s add battery B -emf 10 ; $s add ground GND ; $s add switch SW ; $s add resistor R -r 100
    $s wire B.pos SW.a ; $s wire SW.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
} -body {
    $s open SW  ; set open  [schem::backend::dcref [$s compile]]
    $s close SW ; set closed [schem::backend::dcref [$s compile]]
    # with SW open, the R.a node is pulled to 0 (no source path); closed -> ~10
    set na [$s compile] ; set nid 0
    dict for {i terms} [dict get $na nodes map] { if {"R.a" in $terms} { set nid $i } }
    list [expr {abs([dict get $open $nid]) < 0.1}] [expr {[dict get $closed $nid] > 9.9}]
} -cleanup {$s destroy} -result {1 1}

# ---- the Zig backend emits the expected program, and refuses the rest -----

test zig-emits-divider {the Zig backend emits a well-formed DC solver for the divider} -setup {
    set s [schem::new divider]
    $s add battery B -emf 9 ; $s add ground GND
    $s add resistor R1 -r 1000 ; $s add resistor R2 -r 2000
    $s wire B.pos R1.a ; $s wire R1.b R2.a ; $s wire R2.b GND.t ; $s wire B.neg GND.t
    set z [schem::emit $s zig]
    proc has {h n} { expr {[string first $n $h] >= 0} }
} -body {
    list [has $z "const N: usize = 2;"] \
         [has $z "const SZ: usize = 3;"] \
         [has $z "+= 0.001;"] \
         [has $z "+= 0.0005;"] \
         [has $z "z\[2\] = 9.0;"] \
         [has $z "fn solve("] \
         [has $z "pub fn main()"]
} -cleanup {$s destroy} -result {1 1 1 1 1 1 1}

test zig-refuses-unsupported {the Zig DC backend refuses nonlinear/stateful/coupled parts} -body {
    set s [schem::new x]
    $s add battery B ; $s add ground GND ; $s add diode D
    $s wire B.pos D.a ; $s wire D.k GND.t ; $s wire B.neg GND.t
    set rc [catch {schem::emit $s zig} e]
    $s destroy
    list $rc [string match "*does not yet support*diode*" $e]
} -result {1 1}

test backends-registered {the backend registry lists available targets} -body {
    expr {"zig" in [schem::backends] && "dcref" in [schem::backends]}
} -result 1

cleanupTests
