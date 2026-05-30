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

# --- compile-and-run verification (only when a Zig toolchain is present) ---
# Set SCHEM_ZIG to the zig binary, or have `zig` on PATH; otherwise these are
# skipped.  They emit the backend's Zig, compile + run it, and compare the
# node voltages to the electrical engine.
proc zigExe {} {
    if {[info exists ::env(SCHEM_ZIG)] && [file executable $::env(SCHEM_ZIG)]} {
        return $::env(SCHEM_ZIG)
    }
    set p [auto_execok zig] ; return [expr {$p ne "" ? $p : ""}]
}
testConstraint zig [expr {[zigExe] ne ""}]
proc zigNodes {s} {
    set f [file join [tcltest::temporaryDirectory] z[pid].zig]
    set fh [open $f w] ; puts $fh [schem::emit $s zig] ; close $fh
    set out [exec {*}[zigExe] run $f]
    file delete $f
    set v [dict create]
    foreach line [split $out \n] {
        if {[regexp {N(\d+) = (-?[0-9.]+) V} $line -> nid val]} { dict set v $nid $val }
    }
    return $v
}
proc zigDig {s} {
    set f [file join [tcltest::temporaryDirectory] zd[pid].zig]
    set fh [open $f w] ; puts $fh [schem::emit $s zig -digital] ; close $fh
    set out [exec {*}[zigExe] run $f] ; file delete $f
    set v [dict create]
    foreach line [split $out \n] {
        if {[regexp {N(\d+) = ([01])} $line -> nid val]} { dict set v $nid $val }
    }
    return $v
}
# the two-mode guarantee: compiled digital == compiled literal == engine.
proc digLitEngineAgree {s} {
    $s solve
    set dig [zigDig $s] ; set lit [zigNodes $s] ; set ir [$s compile] ; set ok 1
    dict for {nid terms} [dict get $ir nodes map] {
        if {$nid == 0} continue
        set eng [expr {[$s probe [lindex $terms 0]] > 6 ? 1 : 0}]
        set lb  [expr {[dict get $lit $nid] > 6 ? 1 : 0}]
        if {[dict get $dig $nid] != $eng || $lb != $eng} { set ok 0 }
    }
    return $ok
}
# digEngineAgree -- compiled digital Zig == the engine (no literal comparison;
# for circuits the literal DC backend declines, e.g. tri-state buffers).
proc digEngineAgree {s} {
    $s solve
    set dig [zigDig $s] ; set ir [$s compile] ; set ok 1
    dict for {nid terms} [dict get $ir nodes map] {
        if {$nid == 0} continue
        set eng [expr {[$s probe [lindex $terms 0]] > 6 ? 1 : 0}]
        if {[dict get $dig $nid] != $eng} { set ok 0 }
    }
    return $ok
}
proc nodesMatch {s} {
    $s solve
    set z [zigNodes $s] ; set ir [$s compile] ; set ok 1
    dict for {nid terms} [dict get $ir nodes map] {
        if {$nid == 0} continue
        if {abs([$s probe [lindex $terms 0]] - [dict get $z $nid]) > 1e-3} { set ok 0 }
    }
    return $ok
}
# transient: compile+run the emitted Zig stepper, compare the node-voltage
# time series to the engine's run() node-for-node, step-for-step.
proc tranMatch {s dur dt {events {}}} {
    set ir [$s compile] ; set N [dict get $ir nodes count]
    set terms {}   ;# one representative terminal per node, in node-id order
    for {set nid 1} {$nid <= $N} {incr nid} { lappend terms [lindex [dict get $ir nodes map $nid] 0] }
    # emit zig FIRST, from the pristine schematic (running events would mutate
    # switch state).
    set f [file join [tcltest::temporaryDirectory] zt[pid].zig]
    set fh [open $f w]
    puts $fh [schem::emit $s zig -transient -duration $dur -dt $dt -events $events]
    close $fh
    # engine rows
    set d [$s run -duration $dur -dt $dt -record $terms -events $events]
    set erows {}
    set nt [llength [dict get $d t]]
    for {set i 0} {$i < $nt} {incr i} {
        set row {} ; foreach t $terms { lappend row [lindex [dict get $d $t] $i] }
        lappend erows $row
    }
    # zig rows
    set out [exec {*}[zigExe] run $f] ; file delete $f
    set zrows {}
    foreach line [split $out \n] {
        if {[regexp {^[0-9]} $line]} { lappend zrows [lrange $line 1 end] }
    }
    if {[llength $zrows] != [llength $erows]} { return "rowcount z=[llength $zrows] e=[llength $erows]" }
    for {set i 0} {$i < [llength $erows]} {incr i} {
        foreach ev [lindex $erows $i] zv [lindex $zrows $i] {
            if {abs($ev - $zv) > 1e-3} { return "step $i: e=$ev z=$zv" }
        }
    }
    return ok
}
# clocked digital: drive the engine, digseq and the compiled clocked Zig through
# the same per-cycle schedule ({cycle {op SW} ...}) and assert all three agree on
# every node, every cycle -- the two-mode guarantee extended to sequential logic.
proc seqMatch {s cycles events} {
    # emit + compile + run the clocked Zig from the pristine schematic first
    # (driving the engine below mutates switch state).
    set f [file join [tcltest::temporaryDirectory] zs[pid].zig]
    set fh [open $f w] ; puts $fh [schem::emit $s zig -digital -cycles $cycles -events $events] ; close $fh
    set out [exec {*}[zigExe] run $f] ; file delete $f
    set zbc [dict create]
    foreach line [split $out \n] {
        if {[regexp {^cycle (\d+):(.*)$} $line -> cy rest]} {
            set d [dict create]
            foreach tok $rest { if {[regexp {N(\d+)=([01])} $tok -> n v]} { dict set d $n $v } }
            dict set zbc $cy $d
        }
    }
    set byc [dict create]
    foreach {cy op} $events { dict lappend byc $cy $op }
    set st {}
    for {set cy 0} {$cy < $cycles} {incr cy} {
        if {[dict exists $byc $cy]} { foreach op [dict get $byc $cy] { $s {*}$op } }
        $s solve
        set cir [$s compile]
        set r [schem::backend::digseq $cir $st] ; set st [dict get $r state]
        set lv [dict get $r levels] ; set zc [dict get $zbc $cy]
        dict for {nid terms} [dict get $cir nodes map] {
            if {$nid == 0} continue
            set eng [expr {[$s probe [lindex $terms 0]] > 6 ? 1 : 0}]
            if {$eng != [dict get $lv $nid]}        { return "cycle $cy N$nid: engine=$eng digseq=[dict get $lv $nid]" }
            if {$eng != [dict get $zc $nid]}        { return "cycle $cy N$nid: engine=$eng zig=[dict get $zc $nid]" }
        }
    }
    return ok
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

# ---- the IR lowers a memory chip to its role + address/data/control nodes -

test cir-memory-role {a memory is lowered with its width, mode and pin nodes} -setup {
    set s [schem::new m]
    $s add battery B -emf 12 ; $s add ground G ; $s add memory M -abits 3 -dbits 4
    $s wire B.neg G.t ; $s wire M.GND G.t
    set ir [$s compile]
} -body {
    set e [lindex [lmap el [dict get $ir elements] {expr {[dict get $el class] eq "memory" ? $el : [continue]}}] 0]
    list [dict get $e abits] [dict get $e dbits] [dict get $e mode] \
         [llength [dict get $e address]] [llength [dict get $e di]] [llength [dict get $e do]] \
         [dict get $ir analysis stateful]
} -cleanup {$s destroy} -result {3 4 ram 3 4 4 1}

test cir-dcref-memory {a memory-containing solve driven only by the IR matches the engine} -setup {
    set s [schem::new m]
    $s add battery B -emf 12 ; $s add ground G ; $s add memory M -abits 2 -dbits 2
    $s wire B.neg G.t ; $s wire M.GND G.t ; $s wire B.pos M.A0 ; $s wire B.pos M.WE
    $s solve
} -body {
    set v [schem::backend::dcref [$s compile]]
    set ok 1
    dict for {nid terms} [dict get [$s compile] nodes map] {
        if {$nid == 0} continue
        if {abs([dict get $v $nid] - [$s probe [lindex $terms 0]]) > 1e-4} { set ok 0 }
    }
    set ok
} -cleanup {$s destroy} -result 1

test cir-memory-tape-role {a tape memory lowers with head move pins, no address} -setup {
    set s [schem::new m]
    $s add battery B -emf 12 ; $s add ground G ; $s add memory T -mode tape -dbits 4
    $s wire B.neg G.t ; $s wire T.GND G.t
    set ir [$s compile]
} -body {
    set e [lindex [lmap el [dict get $ir elements] {expr {[dict get $el class] eq "memory" ? $el : [continue]}}] 0]
    list [dict get $e mode] [dict get $e abits] [llength [dict get $e address]] \
         [expr {[dict exists $e move left] && [dict exists $e move right]}]
} -cleanup {$s destroy} -result {tape 0 0 1}

test cir-buffer-role {a tri-state buffer lowers to its in/oe/out role} -setup {
    set s [schem::new b]
    $s add battery B -emf 12 ; $s add ground G ; $s add buffer U
    $s wire B.neg G.t ; $s wire B.pos U.in
    set ir [$s compile]
} -body {
    set e [elem $ir U]
    list [dict get $e class] [expr {[dict exists $e in] && [dict exists $e oe] && [dict exists $e out]}]
} -cleanup {$s destroy} -result {buffer 1}

# busBoard -- two tri-state buffers (A drives HIGH, B drives LOW) on a shared
# bus with a weak keeper, gated by switches SA/SB.  Used by the bus tests.
proc busBoard {} {
    set s [schem::new bus]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add buffer A ; $s wire VCC.pos A.in ; $s add buffer B
    $s add switch SA ; $s wire VCC.pos SA.a ; $s wire SA.b A.oe
    $s add switch SB ; $s wire VCC.pos SB.a ; $s wire SB.b B.oe
    $s wire A.out B.out
    $s add resistor RB -r 100000 ; $s wire A.out RB.a ; $s wire RB.b GND.t
    return $s
}

test cir-dcref-buffer {dcref drives a tri-state bus exactly like the engine} -setup {
    set s [busBoard]
} -body {
    set ok 1
    foreach {sa sb} {0 0  1 0  0 1} {
        if {$sa} {$s close SA} else {$s open SA}
        if {$sb} {$s close SB} else {$s open SB}
        $s solve
        set v [schem::backend::dcref [$s compile]]
        dict for {nid terms} [dict get [$s compile] nodes map] {
            if {$nid == 0} continue
            if {abs([dict get $v $nid] - [$s probe [lindex $terms 0]]) > 1e-3} { set ok 0 }
        }
    }
    set ok
} -cleanup {$s destroy} -result 1

test digref-buffer {digital evaluation drives a tri-state bus like the engine} -setup {
    set s [busBoard]
} -body {
    set ok 1
    foreach {sa sb} {0 0  1 0  0 1} {
        if {$sa} {$s close SA} else {$s open SA}
        if {$sb} {$s close SB} else {$s open SB}
        $s solve
        set d [schem::backend::digref [$s compile]]
        dict for {nid terms} [dict get [$s compile] nodes map] {
            if {$nid == 0} continue
            if {[expr {[$s probe [lindex $terms 0]] > 6 ? 1 : 0}] != [dict get $d $nid]} { set ok 0 }
        }
    }
    set ok
} -cleanup {$s destroy} -result 1

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
         [has $z "stampG(a, 1, 2, 0.001);"] \
         [has $z "stampBranch(a, z, 2, 1, 0, 9.0, 0.0);"] \
         [has $z "fn solve("] \
         [has $z "while (outer < 200)"] \
         [has $z "pub fn main()"]
} -cleanup {$s destroy} -result {1 1 1 1 1 1 1}

test zig-emits-diode {a diode emits the metadata + Newton loop} -setup {
    set s [schem::new di]
    $s add battery B -emf 5 ; $s add ground GND ; $s add diode D ; $s add resistor R -r 1000
    $s wire B.pos D.a ; $s wire D.k R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    set z [schem::emit $s zig]
    proc has {h n} { expr {[string first $n $h] >= 0} }
} -body {
    list [has $z "const ND: usize = 1;"] [has $z "fn diodeComp("] \
         [has $z "var diodeV"] [has $z "if (maxd < 1e-9) break;"]
} -cleanup {$s destroy} -result {1 1 1 1}

test zig-emits-relay {a relay emits the contact arrays + fixed-point loop} -setup {
    set s [schem::new andg]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [schem::lib::and_gate] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    set z [schem::emit $s zig]
    proc has {h n} { expr {[string first $n $h] >= 0} }
} -body {
    list [expr {[has $z "const NR: usize = 0;"] ? 0 : 1}] \
         [has $z "var energized"] \
         [has $z "stampG(a, r_com\[r\], r_no\[r\], 1.0 / RSMALL)"] \
         [has $z "if (!changed) break;"]
} -cleanup {$s destroy} -result {1 1 1 1}

# ---- the IR reproduces nonlinear (diode) and stateful (relay) DC solves ---

test dcref-diode {dcref reproduces a diode's forward drop (Newton, from the IR)} -setup {
    set s [schem::new d]
    $s add battery B -emf 5 ; $s add ground GND ; $s add diode D ; $s add resistor R -r 1000
    $s wire B.pos D.a ; $s wire D.k R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    $s solve
} -body {
    set v [schem::backend::dcref [$s compile]]
    set ir [$s compile] ; set ok 1
    dict for {nid terms} [dict get $ir nodes map] {
        if {$nid == 0} continue
        if {abs([dict get $v $nid] - [$s probe [lindex $terms 0]]) > 1e-3} { set ok 0 }
    }
    set ok
} -cleanup {$s destroy} -result 1

test dcref-fuse-blow {dcref blows an over-rating fuse (a fault state), like the engine} -body {
    proc ::fz {rating} {
        set s [schem::new f]
        $s add battery B -emf 12 ; $s add ground GND ; $s add fuse F -rating $rating ; $s add resistor R -r 5
        $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
        set ir [$s compile] ; set rn 0
        dict for {nid t} [dict get $ir nodes map] { if {"R.a" in $t} {set rn $nid} }
        set v [schem::backend::dcref $ir] ; $s destroy ; return [dict get $v $rn]
    }
    list [expr {abs([fz 1.0]) < 0.01}] [expr {[fz 5.0] > 11.9}]
} -cleanup {rename ::fz {}} -result {1 1}

test digref-matches-engine {digital evaluation == the electrical solve on digital circuits} -body {
    # digref (boolean cycle eval) must agree with the engine (>6 V = HIGH) on
    # every node, every input -- the guarantee that makes a digital backend a
    # verified optimization rather than a shortcut.
    proc ::dboard {builder} {
        set s [schem::new t]
        $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
        set g [$s instantiate [::schem::lib::$builder] U]
        $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
        return [list $s $g]
    }
    proc ::dsw {s name port} { $s add switch $name ; $s wire VCC.pos $name.a ; $s wire $name.b $port }
    set ok 1
    foreach builder {and_gate or_gate nand_gate nor_gate xor_gate half_adder} {
        lassign [dboard $builder] s g
        dsw $s SA [dict get $g A] ; dsw $s SB [dict get $g B]
        foreach {a b} {0 0  0 1  1 0  1 1} {
            if {$a} {$s close SA} else {$s open SA}
            if {$b} {$s close SB} else {$s open SB}
            $s solve
            set d [schem::backend::digref [$s compile]] ; set ir [$s compile]
            dict for {nid terms} [dict get $ir nodes map] {
                if {$nid == 0} continue
                if {[expr {[$s probe [lindex $terms 0]] > 6 ? 1 : 0}] != [dict get $d $nid]} { set ok 0 }
            }
        }
        $s destroy
    }
    rename ::dboard {} ; rename ::dsw {}
    set ok
} -result 1

test digref-refuses-analog {digital mode refuses non-digital parts} -body {
    set s [schem::new a]
    $s add battery B ; $s add ground GND ; $s add diode D ; $s add resistor R
    $s wire B.pos D.a ; $s wire D.k R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
    set rc [catch {schem::backend::digref [$s compile]} e]
    $s destroy
    list $rc [string match "*not digital*diode*" $e]
} -result {1 1}

test digref-refuses-memory {digital mode refuses a (sequential) memory chip} -body {
    set s [schem::new a]
    $s add battery B ; $s add ground GND ; $s add memory M -abits 2 -dbits 2
    $s wire B.neg GND.t ; $s wire M.GND GND.t ; $s wire B.pos M.A0
    set rc [catch {schem::backend::digref [$s compile]} e]
    $s destroy
    list $rc [string match "*not digital*memory*" $e]
} -result {1 1}

# ---- clocked digital (digseq): stateful, == the engine over a sequence ----

test digseq-d-latch {clocked digital matches the engine on a D latch, cycle for cycle} -body {
    # A D latch is sequential: its held state only emerges when state is carried
    # between clock cycles.  Drive the engine and digseq through the same
    # sequence and assert every node agrees every cycle -- including the HOLD.
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::d_latch] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    $s add switch SD ; $s wire VCC.pos SD.a ; $s wire SD.b [dict get $g D]
    $s add switch SC ; $s wire VCC.pos SC.a ; $s wire SC.b [dict get $g CLK]
    set st {} ; set ok 1
    foreach {d c} {1 1   0 1   1 0   0 0   1 1   0 0} {
        if {$d} {$s close SD} else {$s open SD}
        if {$c} {$s close SC} else {$s open SC}
        $s solve
        set cir [$s compile]
        set r [schem::backend::digseq $cir $st] ; set st [dict get $r state]
        set lv [dict get $r levels]
        dict for {nid terms} [dict get $cir nodes map] {
            if {$nid == 0} continue
            if {[expr {[$s probe [lindex $terms 0]] > 6 ? 1 : 0}] != [dict get $lv $nid]} { set ok 0 }
        }
    }
    $s destroy
    set ok
} -result 1

test digseq-memory {clocked digital reproduces a RAM write/read against the engine} -body {
    set AB 2 ; set DB 2
    set s [schem::new m]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add memory M -abits $AB -dbits $DB ; $s wire M.GND GND.t
    foreach p {A0 A1 DI0 DI1 WE CLK} { $s add switch S_$p -state open ; $s wire VCC.pos S_$p.a ; $s wire S_$p.b M.$p }
    proc ::sb {s pre n val} { for {set i 0} {$i<$n} {incr i} { if {[expr {($val>>$i)&1}]} {$s close S_$pre$i} else {$s open S_$pre$i} } }
    set st {} ; set ok 1
    proc ::cyc {s stv okv} {
        upvar 1 $stv st $okv ok
        $s solve ; set cir [$s compile]
        set r [schem::backend::digseq $cir $st] ; set st [dict get $r state]
        set lv [dict get $r levels]
        dict for {nid terms} [dict get $cir nodes map] {
            if {$nid==0} continue
            if {[expr {[$s probe [lindex $terms 0]]>6?1:0}] != [dict get $lv $nid]} { set ok 0 }
        }
    }
    # write 2 -> addr 1, write 1 -> addr 0, then reread addr 1 (still 2)
    sb $s A $AB 1 ; sb $s DI $DB 2 ; $s close S_WE
    $s open S_CLK  ; cyc $s st ok
    $s close S_CLK ; cyc $s st ok
    $s open S_CLK ; $s open S_WE ; sb $s DI $DB 0 ; cyc $s st ok
    sb $s A $AB 0 ; sb $s DI $DB 1 ; $s close S_WE
    $s open S_CLK  ; cyc $s st ok
    $s close S_CLK ; cyc $s st ok
    $s open S_CLK ; $s open S_WE ; sb $s DI $DB 0 ; cyc $s st ok
    sb $s A $AB 1 ; cyc $s st ok
    rename ::sb {} ; rename ::cyc {} ; $s destroy
    set ok
} -result 1

test digseq-tape {clocked digital reproduces an unbounded tape against the engine} -body {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add memory T -mode tape -dbits 4 ; $s wire T.GND GND.t
    foreach p {DI0 DI1 DI2 DI3 WE CLK LEFT RIGHT} { $s add switch S_$p -state open ; $s wire VCC.pos S_$p.a ; $s wire S_$p.b T.$p }
    proc ::sb {s n val} { for {set i 0} {$i<$n} {incr i} { if {[expr {($val>>$i)&1}]} {$s close S_DI$i} else {$s open S_DI$i} } }
    set st {} ; set ok 1
    proc ::cyc {s stv okv} {
        upvar 1 $stv st $okv ok
        $s solve ; set cir [$s compile]
        set r [schem::backend::digseq $cir $st] ; set st [dict get $r state]
        set lv [dict get $r levels]
        dict for {nid terms} [dict get $cir nodes map] {
            if {$nid==0} continue
            if {[expr {[$s probe [lindex $terms 0]]>6?1:0}] != [dict get $lv $nid]} { set ok 0 }
        }
    }
    # write 1,2,3 stepping right; read back stepping left -- the head retraces
    $s close S_WE ; $s close S_RIGHT
    foreach v {1 2 3} { sb $s 4 $v ; $s open S_CLK ; cyc $s st ok ; $s close S_CLK ; cyc $s st ok }
    $s open S_CLK ; $s open S_WE ; $s open S_RIGHT ; sb $s 4 0 ; $s close S_LEFT
    foreach _ {1 2 3} { $s open S_CLK ; cyc $s st ok ; $s close S_CLK ; cyc $s st ok }
    rename ::sb {} ; rename ::cyc {} ; $s destroy
    set ok
} -result 1

test dcref-relay-truthtable {dcref reproduces a relay AND gate's truth table from the IR} -body {
    set res {}
    foreach {a b} {0 0  0 1  1 0  1 1} {
        set s [schem::new t]
        $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
        set g [$s instantiate [schem::lib::and_gate] U]
        $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
        $s add switch SA ; $s wire VCC.pos SA.a ; $s wire SA.b [dict get $g A]
        $s add switch SB ; $s wire VCC.pos SB.a ; $s wire SB.b [dict get $g B]
        if {$a} {$s close SA} ; if {$b} {$s close SB}
        set ir [$s compile] ; set on 0
        dict for {nid terms} [dict get $ir nodes map] { if {[dict get $g OUT] in $terms} {set on $nid} }
        set v [schem::backend::dcref $ir]
        lappend res [expr {[dict get $v $on] > 6 ? 1 : 0}]
        $s destroy
    }
    set res
} -result {0 0 0 1}

test backends-registered {the backend registry lists available targets} -body {
    expr {"zig" in [schem::backends] && "dcref" in [schem::backends]}
} -result 1

# ---- compiled Zig reproduces the engine (when a toolchain is available) ---

test zig-run-divider {emitted Zig compiles and solves the divider} -constraints zig -setup {
    set s [schem::new d]
    $s add battery B -emf 9 ; $s add ground GND ; $s add resistor R1 -r 1000 ; $s add resistor R2 -r 2000
    $s wire B.pos R1.a ; $s wire R1.b R2.a ; $s wire R2.b GND.t ; $s wire B.neg GND.t
} -body { nodesMatch $s } -cleanup {$s destroy} -result 1

test zig-run-diode {emitted Zig (Newton) reproduces a diode drop} -constraints zig -setup {
    set s [schem::new di]
    $s add battery B -emf 5 ; $s add ground GND ; $s add diode D ; $s add resistor R -r 1000
    $s wire B.pos D.a ; $s wire D.k R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
} -body { nodesMatch $s } -cleanup {$s destroy} -result 1

test zig-run-relay {emitted Zig (fixed-point) reproduces a relay AND gate} -constraints zig -setup {
    set s [schem::new andg]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [schem::lib::and_gate] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    $s add switch SA ; $s wire VCC.pos SA.a ; $s wire SA.b [dict get $g A]
    $s add switch SB ; $s wire VCC.pos SB.a ; $s wire SB.b [dict get $g B]
    $s close SA ; $s close SB
} -body { nodesMatch $s } -cleanup {$s destroy} -result 1

# ---- compiled Zig transient reproduces the engine's run() ----------------

test zig-tran-rc {emitted Zig transient matches the engine on an RC charge} -constraints zig -setup {
    set s [schem::new rc]
    $s add battery B -emf 10 ; $s add ground GND ; $s add resistor R -r 100 ; $s add capacitor C -c 1e-3
    $s wire B.pos R.a ; $s wire R.b C.a ; $s wire C.b GND.t ; $s wire B.neg GND.t
} -body { tranMatch $s 0.5 0.05 } -cleanup {$s destroy} -result ok

test zig-tran-rl {emitted Zig transient matches the engine on an RL ramp} -constraints zig -setup {
    set s [schem::new rl]
    $s add battery B -emf 12 ; $s add ground GND ; $s add resistor R -r 10 ; $s add inductor L -l 0.1
    $s wire B.pos R.a ; $s wire R.b L.a ; $s wire L.b GND.t ; $s wire B.neg GND.t
} -body { tranMatch $s 0.05 0.005 } -cleanup {$s destroy} -result ok

test zig-tran-oscillator {emitted Zig transient matches the engine's relay oscillator} -constraints zig -setup {
    set s [schem::new osc]
    $s add battery B -emf 12 ; $s add ground GND ; $s add relay K -coil 100 -pickup 0.05
    $s wire B.pos K.com ; $s wire K.nc K.c1 ; $s wire K.c2 GND.t ; $s wire B.neg GND.t
} -body { tranMatch $s 0.012 0.001 } -cleanup {$s destroy} -result ok

test zig-tran-events {emitted Zig honours timed stimulus (-events), matching the engine} -constraints zig -setup {
    set s [schem::new ev]
    $s add battery B -emf 10 ; $s add ground GND ; $s add switch SW -state open
    $s add resistor R -r 100 ; $s add capacitor C -c 1e-3
    $s wire B.pos SW.a ; $s wire SW.b R.a ; $s wire R.b C.a ; $s wire C.b GND.t ; $s wire B.neg GND.t
} -body { tranMatch $s 0.01 0.001 {0.003 {close SW}} } -cleanup {$s destroy} -result ok

# ---- protective devices blow/trip in the compiled backends ----------------

test zig-run-fuse {compiled DC Zig blows an over-rating fuse} -constraints zig -setup {
    set s [schem::new f]
    $s add battery B -emf 12 ; $s add ground GND ; $s add fuse F -rating 1.0 ; $s add resistor R -r 5
    $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
} -body {
    set z [zigNodes $s]   ;# emits the pristine (intact) circuit, then runs
    set ir [$s compile] ; set rn 0
    dict for {nid t} [dict get $ir nodes map] { if {"R.a" in $t} {set rn $nid} }
    expr {abs([dict get $z $rn]) < 0.01}
} -cleanup {$s destroy} -result 1

test zig-tran-fuse {transient Zig blows a fuse on its i2t curve, matching the engine} -constraints zig -setup {
    set s [schem::new tf]
    $s add battery B -emf 12 ; $s add ground GND ; $s add fuse F -rating 1.0 -i2t 0.05 ; $s add resistor R -r 3
    $s wire B.pos F.a ; $s wire F.b R.a ; $s wire R.b GND.t ; $s wire B.neg GND.t
} -body { tranMatch $s 0.1 0.005 } -cleanup {$s destroy} -result ok

# ---- the two Zig modes agree (digital == literal == engine) --------------

test zig-digital-vs-literal {compiled digital and literal Zig agree, node-for-node} -constraints zig -setup {
    proc ::eboard {builder} {
        set s [schem::new t]
        $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
        set g [$s instantiate [::schem::lib::$builder] U]
        $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
        $s add switch SA ; $s wire VCC.pos SA.a ; $s wire SA.b [dict get $g A]
        $s add switch SB ; $s wire VCC.pos SB.a ; $s wire SB.b [dict get $g B]
        return $s
    }
} -body {
    set ok 1
    foreach builder {and_gate or_gate xor_gate nand_gate nor_gate half_adder} {
        set s [eboard $builder]
        foreach {a b} {0 0  0 1  1 0  1 1} {
            if {$a} {$s close SA} else {$s open SA}
            if {$b} {$s close SB} else {$s open SB}
            if {![digLitEngineAgree $s]} { set ok 0 }
        }
        $s destroy
    }
    set ok
} -cleanup {rename ::eboard {}} -result 1

test zig-digital-full-adder {compiled digital Zig matches the engine on the full adder} -constraints zig -setup {
    set s [schem::new fa]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [schem::lib::full_adder] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    foreach p {A B CIN} { $s add switch S$p ; $s wire VCC.pos S$p.a ; $s wire S$p.b [dict get $g $p] ; $s close S$p }
} -body { digLitEngineAgree $s } -cleanup {$s destroy} -result 1

# ---- clocked digital Zig (sequential) == digseq == the engine -------------

test zig-seq-d-latch {compiled clocked digital matches the engine on a D latch} -constraints zig -setup {
    set s [schem::new latchseq]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::d_latch] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    $s add switch SD ; $s wire VCC.pos SD.a ; $s wire SD.b [dict get $g D]
    $s add switch SC ; $s wire VCC.pos SC.a ; $s wire SC.b [dict get $g CLK]
} -body {
    # write 1 (CLK high), drop D (transparent->0), hold (CLK low), wiggle D,
    # re-clock to 1, then hold -- exercising the seal-in across cycles.
    seqMatch $s 6 {0 {close SD} 0 {close SC} 1 {open SD} 2 {open SC} \
                   3 {close SD} 4 {close SC} 5 {open SC} 5 {open SD}}
} -cleanup {$s destroy} -result ok

test zig-seq-memory {compiled clocked digital reproduces a RAM write/read sequence} -constraints zig -setup {
    set s [schem::new memseq]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add memory M -abits 2 -dbits 2 ; $s wire M.GND GND.t
    foreach p {A0 A1 DI0 DI1 WE CLK} { $s add switch S_$p -state open ; $s wire VCC.pos S_$p.a ; $s wire S_$p.b M.$p }
} -body {
    # write 2->addr1, write 1->addr0, reread addr1 (still 2): a rising CLK edge
    # latches; the word survives, and the cells stay distinct across cycles.
    seqMatch $s 7 {0 {close S_A0} 0 {close S_DI1} 0 {close S_WE} \
                   1 {close S_CLK} \
                   2 {open S_CLK} 2 {open S_WE} 2 {open S_DI1} \
                   3 {open S_A0} 3 {close S_DI0} 3 {close S_WE} \
                   4 {close S_CLK} \
                   5 {open S_CLK} 5 {open S_WE} 5 {open S_DI0} \
                   6 {close S_A0}}
} -cleanup {$s destroy} -result ok

test zig-seq-tape {compiled clocked digital reproduces an unbounded Turing tape} -constraints zig -setup {
    set s [schem::new tapeseq]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    $s add memory T -mode tape -dbits 4 ; $s wire T.GND GND.t
    foreach p {DI0 DI1 WE CLK LEFT RIGHT} { $s add switch S_$p -state open ; $s wire VCC.pos S_$p.a ; $s wire S_$p.b T.$p }
} -body {
    # write 1,2,3 stepping the head right, then step left reading back 3,2,1 --
    # the windowed compiled tape matches the engine's sparse one cycle for cycle.
    seqMatch $s 12 {0 {close S_WE} 0 {close S_RIGHT} 0 {close S_DI0} \
                    1 {close S_CLK} \
                    2 {open S_CLK} 2 {open S_DI0} 2 {close S_DI1} \
                    3 {close S_CLK} \
                    4 {open S_CLK} 4 {close S_DI0} 4 {close S_DI1} \
                    5 {close S_CLK} \
                    6 {open S_CLK} 6 {open S_WE} 6 {open S_RIGHT} 6 {close S_LEFT} 6 {open S_DI0} 6 {open S_DI1} \
                    7 {close S_CLK} 8 {open S_CLK} 9 {close S_CLK} 10 {open S_CLK} 11 {close S_CLK}}
} -cleanup {$s destroy} -result ok

test zig-digital-buffer {compiled digital Zig drives a tri-state bus, matching the engine} -constraints zig -setup {
    set s [busBoard] ; $s close SA   ;# A enabled -> bus HIGH
} -body { digEngineAgree $s } -cleanup {$s destroy} -result 1

test zig-seq-buffer {compiled clocked digital shares a tri-state bus across cycles} -constraints zig -setup {
    set s [busBoard]
} -body {
    # A owns the bus (HIGH), then hands it to B (LOW), then both release (LOW)
    # -- one-hot ownership of the shared line, cycle for cycle vs the engine.
    seqMatch $s 6 {0 {close SA} 2 {open SA} 2 {close SB} 4 {open SB}}
} -cleanup {$s destroy} -result ok

# ---- the capstone: a stored-program machine, verified cycle-for-cycle ------
# Memory (program store) + a relay program counter + tri-state buffers (a
# shared address bus and output bus) make a tiny CPU.  The clocked-digital
# backend must reproduce the whole machine -- counter, RAM and buses together --
# against the electrical engine, every node every cycle.

test digseq-cpu {clocked digital runs a stored-program machine == the engine} -setup {
    set s [cpuBoard]
} -body {
    lassign [cpuProgram] events cycles
    seqDigEngine $s $cycles $events
} -cleanup {$s destroy} -result ok

test zig-seq-cpu {clocked digital Zig runs the stored-program machine == engine} -constraints zig -setup {
    set s [cpuBoard]
} -body {
    lassign [cpuProgram] events cycles
    seqMatch $s $cycles $events
} -cleanup {$s destroy} -result ok

cleanupTests
