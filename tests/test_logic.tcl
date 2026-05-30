# test_logic.tcl --
#
# The relay standard-cell library: proof, by truth table, that Schem is
# computationally universal.  Every gate, the adder and the latch are built
# only from relays and solved by the electrical engine -- no logic is
# hard-coded anywhere.
#
#   tclsh tests/test_logic.tcl

package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic.tcl]

# hi -- is a level node logic-HIGH?
proc hi {s term} { return [expr {[$s probe $term] > 6 ? 1 : 0}] }

# board -- a supply rail with a single instantiated cell wired up.
proc board {builder} {
    set s [schem::new t]
    $s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
    set g [$s instantiate [::schem::lib::$builder] U]
    $s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t
    return [list $s $g]
}

# inSwitch -- add an input switch from VCC driving an input port.
proc inSwitch {s name port} {
    $s add switch $name
    $s wire VCC.pos $name.a ; $s wire $name.b $port
}
proc setSw {s name v} { if {$v} {$s close $name} else {$s open $name} }

# truth2 -- drive A,B over all four combinations; return the OUT bit string.
proc truth2 {builder {outport OUT}} {
    lassign [board $builder] s g
    inSwitch $s SA [dict get $g A]
    inSwitch $s SB [dict get $g B]
    set out ""
    foreach {a b} {0 0  0 1  1 0  1 1} {
        setSw $s SA $a ; setSw $s SB $b ; $s solve
        append out [hi $s [dict get $g $outport]]
    }
    $s destroy
    return $out
}

# ---- primitive gates ----------------------------------------------------

test gate-and  {AND: NO contacts in series}       -body {truth2 and_gate}  -result 0001
test gate-or   {OR: NO contacts in parallel}      -body {truth2 or_gate}   -result 0111
test gate-nand {NAND: NC contacts in parallel}    -body {truth2 nand_gate} -result 1110
test gate-nor  {NOR: NC contacts in series}       -body {truth2 nor_gate}  -result 1000

test gate-not {NOT: one NC contact inverts} -body {
    lassign [board not_gate] s g
    inSwitch $s SA [dict get $g A]
    setSw $s SA 0 ; $s solve ; set lo [hi $s [dict get $g OUT]]
    setSw $s SA 1 ; $s solve ; set hiv [hi $s [dict get $g OUT]]
    $s destroy
    list $lo $hiv
} -result {1 0}

# ---- composition --------------------------------------------------------

test gate-xor {XOR composed from OR, NAND, AND} -body {truth2 xor_gate} -result 0110

test half-adder {SUM = A^B, CARRY = A&B} -body {
    list [truth2 half_adder SUM] [truth2 half_adder CARRY]
} -result {0110 0001}

# ---- arithmetic: a relay binary full adder ------------------------------

test full-adder {SUM=A^B^Cin, COUT=majority across all 8 inputs} -body {
    lassign [board full_adder] s g
    inSwitch $s SA [dict get $g A]
    inSwitch $s SB [dict get $g B]
    inSwitch $s SC [dict get $g CIN]
    set ok 1
    foreach {a b c} {0 0 0  0 0 1  0 1 0  0 1 1  1 0 0  1 0 1  1 1 0  1 1 1} {
        setSw $s SA $a ; setSw $s SB $b ; setSw $s SC $c ; $s solve
        set sum  [hi $s [dict get $g SUM]]
        set cout [hi $s [dict get $g COUT]]
        if {$sum != ($a^$b^$c)} { set ok 0 }
        if {$cout != (($a&$b)|($c&($a^$b)))} { set ok 0 }
    }
    $s destroy
    set ok
} -result 1

test full-adder-size {the full adder is a real, deep relay circuit} -body {
    lassign [board full_adder] s g
    set relays 0
    foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr relays } }
    $s destroy
    # two half-adders (2 XOR + 2 AND) + an OR = 18 relays
    expr {$relays == 18}
} -result 1

# ---- memory: the seal-in latch ------------------------------------------

test sr-latch {a relay latch holds its bit (set, hold, reset)} -body {
    lassign [board sr_latch] s g
    set seq {}
    $s solve                         ; lappend seq [$s energized U/K]  ;# idle: 0
    $s press U/SET   ; $s solve       ; lappend seq [$s energized U/K]  ;# set: 1
    $s release U/SET ; $s solve       ; lappend seq [$s energized U/K]  ;# hold: 1
    $s solve                         ; lappend seq [$s energized U/K]  ;# still: 1
    $s open U/RST    ; $s solve       ; lappend seq [$s energized U/K]  ;# reset: 0
    $s close U/RST   ; $s solve       ; lappend seq [$s energized U/K]  ;# stays: 0
    $s destroy
    set seq
} -result {0 1 1 1 0 0}

cleanupTests
