# power_supply.tcl --
#
# Power-supply design with REAL parts -- the workflow an engineer actually
# follows, and the design review a tech does before trusting a board.  Run:
#
#   tclsh examples/power_supply.tcl
#
# It builds a simple DC supply path -- a series PROTECTION diode (reverse-
# polarity / blocking) feeding a reservoir cap and a load -- then asks the
# question that matters: are the PARTS right?  The same circuit passes or
# fails depending on whether the diode can take the current, which is exactly
# what the ratings review catches.
#
# NOTE: this is a DC rail with a series blocking diode, NOT a rectifier.
# Rectification converts AC to DC and needs an AC source -- see
# examples/ac_dc_supply.tcl for a real full-wave bridge rectifier.
set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib parts.tcl]
source [file join $here .. lib ratings.tcl]

proc rule {t} { puts "\n========== $t ==========" }

# --------------------------------------------------------------------
rule "A 12 V rail: series blocking diode + reservoir + 47 ohm load"
# --------------------------------------------------------------------
# 1N4007 (1000 V, 1 A) as a reverse-polarity protection diode; it feeds a
# 470 uF reservoir and a 47 ohm load drawing ~0.25 A.  Well within ratings.
set s [schem::new rail12]
$s add battery SRC -emf 12
$s add ground GND
::schem::parts::place $s D1 1N4007
::schem::parts::place $s C1 CAP_470u_35V
$s add resistor RL -r 47
$s wire SRC.pos D1.a
$s wire D1.k C1.a ; $s wire C1.b GND.t
$s wire D1.k RL.a ; $s wire RL.b GND.t
$s wire SRC.neg GND.t
$s solve
puts "Vout = [format %.2f [$s probe RL.a]] V   Iload = [format %.3f [$s current RL]] A"
puts [::schem::ratings::report $s]

# --------------------------------------------------------------------
rule "WRONG part: a 200 mA signal diode on a 0.25 A rail"
# --------------------------------------------------------------------
# The math is identical -- but a 1N4148 is a 200 mA signal diode.  At a quarter
# amp it is 20% over its forward-current rating and cooks.  This is the failure
# a simulator that ignores part ratings would happily pass.
set s2 [schem::new rail12bad]
$s2 add battery SRC -emf 12
$s2 add ground GND
::schem::parts::place $s2 D1 1N4148
::schem::parts::place $s2 C1 CAP_470u_35V
$s2 add resistor RL -r 47
$s2 wire SRC.pos D1.a
$s2 wire D1.k C1.a ; $s2 wire C1.b GND.t
$s2 wire D1.k RL.a ; $s2 wire RL.b GND.t
$s2 wire SRC.neg GND.t
$s2 solve
puts "Vout = [format %.2f [$s2 probe RL.a]] V   Iload = [format %.3f [$s2 current RL]] A"
puts [::schem::ratings::report $s2]

# --------------------------------------------------------------------
rule "Reservoir over-voltage: a 16 V cap on a 24 V rail"
# --------------------------------------------------------------------
# Pick the wrong capacitor voltage rating and the review flags it before the
# cap vents.  A 1000 uF 16 V part on a 24 V rail is 150% over -- a classic
# magic-smoke mistake.
set s3 [schem::new capvolt]
$s3 add battery SRC -emf 24
$s3 add ground GND
::schem::parts::place $s3 D1 1N4007
::schem::parts::place $s3 C1 CAP_1000u_16V
$s3 add resistor RL -r 220
$s3 wire SRC.pos D1.a
$s3 wire D1.k C1.a ; $s3 wire C1.b GND.t
$s3 wire D1.k RL.a ; $s3 wire RL.b GND.t
$s3 wire SRC.neg GND.t
$s3 solve
puts "Vout = [format %.2f [$s3 probe RL.a]] V"
puts [::schem::ratings::report $s3]

puts "\nThe schematic is the same in all three.  What changes is the PARTS --"
puts "and whether they survive the job.  That is the review this automates."
