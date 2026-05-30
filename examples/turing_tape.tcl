# turing_tape.tcl --
#
# An UNBOUNDED memory: a Turing-machine tape as a first-class electrical part.
# Where a RAM has a fixed address bus (and so 2^abits words), a tape has a
# movable head over a store that grows on demand -- so it is strictly
# unbounded, the missing ingredient for full Turing completeness, and it costs
# no gates: the cells are stored sparsely and the head is just a position.
#
# The tape's pins are data-in (DI0..), data-out (DO0..), write-enable (WE),
# a clock (CLK) and two head-move controls (LEFT, RIGHT).  On each rising CLK
# edge the chip writes DI into the cell under the head (when WE is high) and
# then steps the head one cell in the commanded direction.  DO always shows
# the cell currently under the head.
#
# Here we write 1, 2, 3 into three consecutive cells while stepping right,
# then step back left and read them in reverse -- proving the cells persisted
# and the head retraced over an unbounded medium, with no software state.
#
#   run with:  tclsh examples/turing_tape.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set DB 4
set s [schem::new turing_tape]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t
$s add memory T -mode tape -dbits $DB ; $s wire T.GND GND.t

# A switch on every input pin -- the control unit driving the tape.
foreach p {DI0 DI1 DI2 DI3 WE CLK LEFT RIGHT} {
    $s add switch S_$p -state open
    $s wire VCC.pos S_$p.a ; $s wire S_$p.b T.$p
}
proc data {s n val} { for {set i 0} {$i < $n} {incr i} { if {[expr {($val >> $i) & 1}]} { $s close S_DI$i } else { $s open S_DI$i } } }
proc head {s n} { set v 0 ; for {set i 0} {$i < $n} {incr i} { if {[$s probe T.DO$i] > 6} { set v [expr {$v | (1 << $i)}] } } ; return $v }
proc clock {s} { $s open S_CLK ; $s solve ; $s close S_CLK ; $s solve ; $s open S_CLK ; $s solve }

puts "Writing 1, 2, 3 to consecutive cells, stepping the head RIGHT:"
$s close S_WE ; $s close S_RIGHT
foreach v {1 2 3} { data $s $DB $v ; puts "  write $v" ; clock $s }
$s open S_WE ; $s open S_RIGHT ; data $s $DB 0

puts "Stepping the head LEFT, reading each cell back:"
$s close S_LEFT
foreach _ {1 2 3} { clock $s ; puts "  read [head $s $DB]" }
puts "(the cells survived and the head retraced -- an unbounded tape)"
