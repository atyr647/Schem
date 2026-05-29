# relay_and_gate.schem.tcl --
#
# Conditional behaviour with no "if": two relays whose NO contacts are
# wired in series form a logical AND.  The load is powered only when both
# coils are energised (both buttons pressed).  Conditional routing emerges
# from the electricity.
#
#   run with:  bin/schem examples/relay_and_gate.schem.tcl

$s add battery BC -emf 9     ;# control supply
$s add battery BL -emf 12    ;# load supply
$s add ground  GND
$s add button  A
$s add button  B
$s add relay   KA -coil 100 -pickup 0.02
$s add relay   KB -coil 100 -pickup 0.02
$s add resistor LOAD -r 1000

# Control side: each button energises its relay coil.
$s wire BC.pos A.a ; $s wire A.b KA.c1 ; $s wire KA.c2 GND.t
$s wire BC.pos B.a ; $s wire B.b KB.c1 ; $s wire KB.c2 GND.t
$s wire BC.neg GND.t

# Switched side: KA.NO in series with KB.NO feeds the load.
$s wire BL.pos KA.com
$s wire KA.no  KB.com
$s wire KB.no  LOAD.a
$s wire LOAD.b GND.t
$s wire BL.neg GND.t

proc state {s} {
    return "A=[$s energized KA] B=[$s energized KB] -> LOAD=[format %.4f [$s current LOAD]] A"
}

$s solve ; puts "neither pressed : [state $s]"
$s press A ; $s solve ; puts "A only         : [state $s]"
$s release A ; $s press B ; $s solve ; puts "B only         : [state $s]"
$s press A ; $s solve ; puts "both pressed   : [state $s]"
puts ""
