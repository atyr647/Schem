# voltage_divider.schem.tcl --
#
# The "hello world" of Schem.  A 9 V source across two resistors in
# series; the tap between them sits at a fraction of the source set by the
# resistor ratio (Ohm's law + KVL):  Vout = E * R2/(R1+R2).
#
#   run with:  bin/schem examples/voltage_divider.schem.tcl

$s add battery  B  -emf 9
$s add ground   GND
$s add resistor R1 -r 1000
$s add resistor R2 -r 2000

$s wire B.pos R1.a
$s wire R1.b  R2.a      ;# OUT is this node -> expect 6 V
$s wire R2.b  GND.t
$s wire B.neg GND.t

$s solve
