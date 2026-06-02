# accumulator.tcl --
#
# A running total built from nothing but electrical assemblies: an n-bit
# register holding the total, an n-bit adder, and a clock.  The register's
# output feeds the adder; the adder's sum feeds back to the register's input;
# each clock edge latches the new total.  This is stateful arithmetic --
# Q := Q + IN every tick -- with no software anywhere, only relays.
#
#   register (Q) --> adder (Q + IN) --> register input --(clock)--> Q
#
#   run with:  tclsh examples/accumulator.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic logic.tcl]
source [file join $here .. lib logic catalog.tcl]

set N 4
set s [schem::new accumulator]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
set g [$s instantiate [schem::lib::accumulator acc $N] U]
$s wire [dict get $g VCC] VCC.pos ; $s wire [dict get $g GND] GND.t

$s add switch SCLK ; $s wire VCC.pos SCLK.a ; $s wire SCLK.b [dict get $g CLK]
for {set i 0} {$i < $N} {incr i} {
    $s add switch SI$i ; $s wire VCC.pos SI$i.a ; $s wire SI$i.b [dict get $g IN$i]
}
proc load {s n val} { for {set i 0} {$i < $n} {incr i} { if {[expr {($val>>$i)&1}]} {$s close SI$i} else {$s open SI$i} } }
proc total {s g n} { set v 0 ; for {set i 0} {$i < $n} {incr i} { if {[$s probe [dict get $g Q$i]] > 6} { set v [expr {$v|(1<<$i)}] } } ; return $v }
proc tick {s} { $s open SCLK ; $s solve ; $s close SCLK ; $s solve }

set relays 0 ; foreach c [$s components] { if {[$s typeof $c] eq "relay"} { incr relays } }
puts "A $N-bit relay accumulator ($relays relays, [llength [$s components]] components)\n"
$s open SCLK ; $s solve
puts [format "  power on            total = %2d" [total $s $g $N]]
load $s $N 1
puts "  input = 1, then clock repeatedly:"
for {set t 1} {$t <= 6} {incr t} { tick $s ; puts [format "    tick %d            total = %2d" $t [total $s $g $N]] }
load $s $N 3
puts "  change input to 3:"
for {set t 1} {$t <= 3} {incr t} { tick $s ; puts [format "    tick %d            total = %2d" $t [total $s $g $N]] }
$s destroy
puts ""
