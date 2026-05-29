# test_seq.tcl --
#
# Clocked (sequential) relay logic: a gated D latch, a rising-edge D
# flip-flop, a toggle flip-flop and a 2-bit ripple counter -- all built
# only from relays and solved by the electrical engine.  Memory and timing
# come from the engine's *persistent relay state*: each solve settles one
# clock event, and the seal-in hold carries a bit between solves.  This is
# what proves Schem can express not just combinational logic but state
# machines.
#
#   tclsh tests/test_seq.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic.tcl]

proc hi {s term} { return [expr {[$s probe $term] > 6 ? 1 : 0}] }

# board -- a supply rail with a single instantiated cell wired up.
proc board {builder} {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::$builder] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    return [list $s $g]
}
proc inSwitch {s name port} {
    $s add switch $name
    $s wire VCC.pos $name.a ; $s wire $name.b $port
}
proc setSw {s name v} { if {$v} {$s close $name} else {$s open $name} }

# tick -- one full clock cycle on switch `clk`: drop LOW (settle), then
# raise HIGH (the rising edge that triggers an edge-sensitive cell).
proc tick {s clk} { setSw $s $clk 0 ; $s solve ; setSw $s $clk 1 ; $s solve }

# ---- gated D latch: transparent while CLK high, holds while CLK low ------

test d-latch-transparent {Q follows D while CLK is high} -body {
    lassign [board d_latch] s g
    inSwitch $s SD [dict get $g D] ; inSwitch $s SC [dict get $g CLK]
    setSw $s SC 1
    setSw $s SD 1 ; $s solve ; set a [hi $s [dict get $g Q]]
    setSw $s SD 0 ; $s solve ; set b [hi $s [dict get $g Q]]
    $s destroy
    list $a $b
} -result {1 0}

test d-latch-hold {Q is frozen while CLK is low, regardless of D} -body {
    lassign [board d_latch] s g
    inSwitch $s SD [dict get $g D] ; inSwitch $s SC [dict get $g CLK]
    # capture a 1, then drop the clock and wiggle D
    setSw $s SC 1 ; setSw $s SD 1 ; $s solve
    setSw $s SC 0 ; $s solve              ;# hold
    setSw $s SD 0 ; $s solve ; set held1 [hi $s [dict get $g Q]]
    setSw $s SD 1 ; $s solve ; set held2 [hi $s [dict get $g Q]]
    $s destroy
    list $held1 $held2
} -result {1 1}

test d-latch-nq {NQ is the complement of Q} -body {
    lassign [board d_latch] s g
    inSwitch $s SD [dict get $g D] ; inSwitch $s SC [dict get $g CLK]
    setSw $s SC 1
    setSw $s SD 1 ; $s solve ; set h "[hi $s [dict get $g Q]][hi $s [dict get $g NQ]]"
    setSw $s SD 0 ; $s solve ; set l "[hi $s [dict get $g Q]][hi $s [dict get $g NQ]]"
    $s destroy
    list $h $l
} -result {10 01}

# ---- rising-edge D flip-flop --------------------------------------------

test dff-samples-on-edge {Q takes D's value at the rising edge} -body {
    lassign [board d_flipflop] s g
    inSwitch $s SD [dict get $g D] ; inSwitch $s SC [dict get $g CLK]
    setSw $s SC 0
    setSw $s SD 1 ; tick $s SC ; set q1 [hi $s [dict get $g Q]]
    setSw $s SD 0 ; tick $s SC ; set q0 [hi $s [dict get $g Q]]
    $s destroy
    list $q1 $q0
} -result {1 0}

test dff-edge-only {D changing while CLK stays high does not reach Q} -body {
    lassign [board d_flipflop] s g
    inSwitch $s SD [dict get $g D] ; inSwitch $s SC [dict get $g CLK]
    setSw $s SC 0
    setSw $s SD 1 ; tick $s SC          ;# clock a 1 in -> Q=1
    # now change D with the clock held HIGH: Q must not follow (no new edge)
    setSw $s SD 0 ; $s solve
    set q [hi $s [dict get $g Q]]
    $s destroy
    set q
} -result 1

# ---- toggle flip-flop ----------------------------------------------------

test tff-toggles {Q inverts on every rising edge} -body {
    lassign [board t_flipflop] s g
    inSwitch $s SC [dict get $g CLK]
    setSw $s SC 0 ; $s solve
    set seq [hi $s [dict get $g Q]]
    for {set i 0} {$i < 4} {incr i} {
        tick $s SC ; append seq [hi $s [dict get $g Q]]
    }
    $s destroy
    set seq
} -result 01010

# ---- 2-bit ripple counter -----------------------------------------------

test counter2-counts {Q1Q0 steps 00,01,10,11,00 on successive clocks} -body {
    lassign [board counter2] s g
    inSwitch $s SC [dict get $g CLK]
    setSw $s SC 0 ; $s solve
    set seq [list "[hi $s [dict get $g Q1]][hi $s [dict get $g Q0]]"]
    for {set i 0} {$i < 5} {incr i} {
        tick $s SC
        lappend seq "[hi $s [dict get $g Q1]][hi $s [dict get $g Q0]]"
    }
    $s destroy
    set seq
} -result {00 01 10 11 00 01}

test counter2-is-deep-relay-logic {the counter is a real, deep relay circuit} -body {
    lassign [board counter2] s g
    set relays 0
    foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr relays } }
    $s destroy
    # 2 T-FFs x (1 D-FF = 2 D-latches x 4 relays) = 16 relays
    expr {$relays == 16}
} -result 1

cleanupTests
