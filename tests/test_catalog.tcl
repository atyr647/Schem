# test_catalog.tcl --
#
# The circuit catalog: standard electrical assemblies (register, adder,
# counter, decoder, selector) built only from the relay logic library and
# solved by the electrical engine.  These are the reusable blocks larger
# machines (accumulators, sequencers, computers) are assembled from.
#
#   tclsh tests/test_catalog.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic.tcl]
source [file join $here .. lib catalog.tcl]

proc hi {s t} { return [expr {[$s probe $t] > 6 ? 1 : 0}] }
proc board {builder args} {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::$builder {*}$args] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    return [list $s $g]
}
proc insw {s g port name} {
    $s add switch $name ; $s wire VCC.pos $name.a ; $s wire $name.b [dict get $g $port]
}
proc setsw {s n v} { if {$v} {$s close $n} else {$s open $n} }
proc readbits {s g prefix n} {
    set v 0
    for {set i 0} {$i < $n} {incr i} {
        if {[hi $s [dict get $g $prefix$i]]} { set v [expr {$v | (1<<$i)}] }
    }
    return $v
}

# ---- decoder: exactly one output high, matching the address --------------

test decoder-onehot {a 2->4 decoder drives exactly the addressed line} -body {
    lassign [board decoder dec 2] s g
    insw $s $g A0 SA0 ; insw $s $g A1 SA1
    set res {}
    foreach {a0 a1} {0 0  0 1  1 0  1 1} {
        setsw $s SA0 $a0 ; setsw $s SA1 $a1 ; $s solve
        set hot -1
        for {set k 0} {$k < 4} {incr k} { if {[hi $s [dict get $g Y$k]]} { lappend hot $k } }
        lappend res $hot
    }
    $s destroy
    set res
} -result {{-1 0} {-1 1} {-1 2} {-1 3}}

# ---- selector: OUT follows the addressed input ---------------------------

test selector-routes {a 2:1 selector passes the addressed input to OUT} -body {
    lassign [board selector sel 1] s g
    insw $s $g I0 SI0 ; insw $s $g I1 SI1 ; insw $s $g A0 SA
    setsw $s SI0 0 ; setsw $s SI1 1
    setsw $s SA 0 ; $s solve ; set a [hi $s [dict get $g OUT]]
    setsw $s SA 1 ; $s solve ; set b [hi $s [dict get $g OUT]]
    # and the other way round: I0=1, I1=0
    setsw $s SI0 1 ; setsw $s SI1 0
    setsw $s SA 0 ; $s solve ; set c [hi $s [dict get $g OUT]]
    setsw $s SA 1 ; $s solve ; set d [hi $s [dict get $g OUT]]
    $s destroy
    list $a $b $c $d
} -result {0 1 1 0}

# ---- adder: multi-bit arithmetic -----------------------------------------

test adder-4bit {a 4-bit ripple adder computes A + B (+carry)} -body {
    lassign [board adder add 4] s g
    for {set i 0} {$i < 4} {incr i} { insw $s $g A$i SA$i ; insw $s $g B$i SB$i }
    insw $s $g CIN SC
    proc load {s prefix val n} {
        for {set i 0} {$i < $n} {incr i} { setsw $s $prefix$i [expr {($val>>$i)&1}] }
    }
    set ok 1
    foreach {a b} {9 5  7 7  15 1  3 4} {
        load $s SA $a 4 ; load $s SB $b 4 ; setsw $s SC 0 ; $s solve
        set sum [readbits $s $g S 4]
        if {[hi $s [dict get $g COUT]]} { incr sum 16 }
        if {$sum != ($a+$b)} { set ok 0 }
    }
    $s destroy
    set ok
} -result 1

# ---- register: clocked storage that holds ---------------------------------

test register-stores {a register captures D on the edge and holds it} -body {
    lassign [board register reg 4] s g
    insw $s $g CLK SCLK
    for {set i 0} {$i < 4} {incr i} { insw $s $g D$i SD$i }
    setsw $s SCLK 0
    foreach {i v} {0 0 1 1 2 1 3 0} { setsw $s SD$i $v }   ;# D = 0110
    $s solve ; setsw $s SCLK 1 ; $s solve                  ;# clock it in
    set loaded [readbits $s $g Q 4]
    foreach {i v} {0 1 1 0 2 0 3 1} { setsw $s SD$i $v }   ;# change D, clock high
    $s solve
    set held [readbits $s $g Q 4]
    $s destroy
    list $loaded $held
} -result {6 6}

# ---- counter: counts the full range and wraps ----------------------------

test counter-3bit {a 3-bit counter steps 0..7 and wraps} -body {
    lassign [board counter cnt 3] s g
    insw $s $g CLK SCLK
    setsw $s SCLK 0 ; $s solve
    set seq [readbits $s $g Q 3]
    for {set t 0} {$t < 8} {incr t} {
        setsw $s SCLK 0 ; $s solve ; setsw $s SCLK 1 ; $s solve
        lappend seq [readbits $s $g Q 3]
    }
    $s destroy
    set seq
} -result {0 1 2 3 4 5 6 7 0}

# ---- sequencer: one-hot control phases stepping in order -----------------

test sequencer {each clock advances to the next phase line, cycling} -body {
    lassign [board sequencer seq 2] s g
    insw $s $g CLK SCLK
    proc tick {s} { setsw $s SCLK 0 ; $s solve ; setsw $s SCLK 1 ; $s solve }
    proc activephase {s g} {
        for {set k 0} {$k < 4} {incr k} { if {[hi $s [dict get $g P$k]]} { return $k } }
        return -1
    }
    setsw $s SCLK 0 ; $s solve
    set seq [activephase $s $g]
    for {set t 0} {$t < 5} {incr t} { tick $s ; lappend seq [activephase $s $g] }
    $s destroy
    set seq
} -result {0 1 2 3 0 1}

# ---- accumulator: stateful arithmetic (a running total) ------------------

test accumulator {Q := Q + IN on each clock} -body {
    lassign [board accumulator acc 4] s g
    insw $s $g CLK SCLK
    for {set i 0} {$i < 4} {incr i} { insw $s $g IN$i SI$i }
    proc load {s val} { for {set i 0} {$i < 4} {incr i} { setsw $s SI$i [expr {($val>>$i)&1}] } }
    proc tick {s} { setsw $s SCLK 0 ; $s solve ; setsw $s SCLK 1 ; $s solve }
    setsw $s SCLK 0 ; $s solve
    set seq [readbits $s $g Q 4]
    load $s 1
    for {set t 0} {$t < 4} {incr t} { tick $s ; lappend seq [readbits $s $g Q 4] }
    load $s 3
    for {set t 0} {$t < 2} {incr t} { tick $s ; lappend seq [readbits $s $g Q 4] }
    $s destroy
    set seq
} -result {0 1 2 3 4 7 10}

# ---- integration: a controlled multiplier that computes and HALTS --------
# Datapath = a 3-bit accumulator; control = a 2-bit step counter + a seal-in
# halt latch that gates the operand off once the count reaches 3.  Proves
# control + datapath + state cooperating: it computes operand x 3, then stops.

test computing-panel {a controlled accumulator multiplies then halts} -body {
    set p [schem::panel m]
    $p add battery VCC -emf 12 ; $p add ground GND ; $p wire VCC.neg GND.t
    set acc [$p instantiate [schem::lib::accumulator AC 3] ACC]
    set cnt [$p instantiate [schem::lib::counter CT 2] CNT]
    set hd  [$p instantiate [schem::lib::and_gate] HD]
    foreach m [list $acc $cnt $hd] { $p wire [dict get $m VCC] VCC.pos ; $p wire [dict get $m GND] GND.t }
    $p add switch SCLK ; $p wire VCC.pos SCLK.a
    $p wire SCLK.b [dict get $acc CLK] ; $p wire SCLK.b [dict get $cnt CLK]
    $p wire [dict get $cnt Q0] [dict get $hd A] ; $p wire [dict get $cnt Q1] [dict get $hd B]
    $p add relay KS -coil 100 -pickup 0.01
    $p wire [dict get $hd OUT] KS.c1 ; $p wire KS.c2 GND.t
    $p add relay HL -coil 100 -pickup 0.01
    $p wire VCC.pos KS.com ; $p wire VCC.pos HL.com
    $p wire KS.no HL.c1 ; $p wire HL.no HL.c1 ; $p wire HL.c2 GND.t
    $p add resistor RPD -r 10000 ; $p wire HL.nc RPD.a ; $p wire RPD.b GND.t
    for {set i 0} {$i < 3} {incr i} {
        set ag [$p instantiate [schem::lib::and_gate] G$i]
        $p wire [dict get $ag VCC] VCC.pos ; $p wire [dict get $ag GND] GND.t
        $p add switch OP$i ; $p wire VCC.pos OP$i.a ; $p wire OP$i.b [dict get $ag A]
        $p wire HL.nc [dict get $ag B]
        $p wire [dict get $ag OUT] [dict get $acc IN$i]
    }
    proc total {p acc} { set v 0 ; for {set i 0} {$i<3} {incr i} { if {[$p probe [dict get $acc Q$i]] > 6} {set v [expr {$v|(1<<$i)}]} } ; return $v }
    proc tick {p} { $p open SCLK ; $p solve ; $p close SCLK ; $p solve }
    $p close OP1   ;# operand = 2
    $p open SCLK ; $p solve
    set seq [total $p $acc]
    for {set k 0} {$k < 4} {incr k} { tick $p ; lappend seq [total $p $acc] }
    $p destroy
    set seq            ;# 0, then 2,4,6, then frozen at 6 (2 x 3, halted)
} -result {0 2 4 6 6}

# ---- grid: panels composed at the top of the hierarchy -------------------

test computing-grid {a grid holds independent panels, addressed by full path} -body {
    proc cpanel {name} {
        set pan [schem::panel $name]
        set c [$pan instantiate [schem::lib::counter CT 2] C]
        foreach p {VCC GND CLK Q0 Q1} { $pan expose $p [dict get $c $p] }
        return $pan
    }
    set grid [schem::grid plant]
    $grid add battery VCC -emf 12 ; $grid add ground GND ; $grid wire VCC.neg GND.t
    set A [$grid instantiate [cpanel A] A] ; set B [$grid instantiate [cpanel B] B]
    foreach m [list $A $B] { $grid wire [dict get $m VCC] VCC.pos ; $grid wire [dict get $m GND] GND.t }
    $grid add switch CKA ; $grid wire VCC.pos CKA.a ; $grid wire CKA.b [dict get $A CLK]
    $grid add switch CKB ; $grid wire VCC.pos CKB.a ; $grid wire CKB.b [dict get $B CLK]
    proc rd {grid m} { set v 0 ; foreach b {0 1} { if {[$grid probe [dict get $m Q$b]] > 6} { set v [expr {$v|(1<<$b)}] } } ; return $v }
    proc tk {grid sw} { $grid open $sw ; $grid solve ; $grid close $sw ; $grid solve }
    $grid open CKA ; $grid open CKB ; $grid solve
    tk $grid CKA ; tk $grid CKA ; tk $grid CKB    ;# A twice, B once
    # A=2, B=1, and a component is addressable by its grid/panel/circuit path
    set deep [expr {"A/C/T0/FF/M/M/KC" in [$grid components] || \
                    [llength [lsearch -all -glob [$grid components] A/C/*]] > 0}]
    set res [list [rd $grid $A] [rd $grid $B] $deep]
    $grid destroy
    set res
} -result {2 1 1}

cleanupTests
