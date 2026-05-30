# safety_interlock.schem.tcl --
#
# A safety interlock: the load can only be energised when *every* guard
# switch in the chain is closed.  Continuity is broken if any one is open
# -- no "AND" operator exists, the series wiring *is* the conjunction.
#
#   run with:  bin/schem examples/safety_interlock.schem.tcl

$s add battery  B    -emf 24
$s add ground   GND
$s add switch   GUARD1 -state closed
$s add switch   GUARD2 -state closed
$s add switch   ESTOP  -state closed   ;# emergency stop (normally closed)
$s add resistor LOAD   -r 240          ;# 100 mA load when all closed

$s wire B.pos   GUARD1.a
$s wire GUARD1.b GUARD2.a
$s wire GUARD2.b ESTOP.a
$s wire ESTOP.b  LOAD.a
$s wire LOAD.b   GND.t
$s wire B.neg    GND.t

$s solve
puts "All guards closed -> LOAD current = [format %.4f [$s current LOAD]] A"

# Trip the emergency stop: the chain opens, the load drops out.
$s open ESTOP
$s solve
puts "E-stop open       -> LOAD current = [format %.4f [$s current LOAD]] A"
puts ""
