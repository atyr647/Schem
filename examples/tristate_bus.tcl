# tristate_bus.tcl --
#
# A shared data bus -- the way real chips put many talkers on a few wires.
# A tri-state buffer drives its output only while its output-enable is high;
# disabled, it goes high-impedance (Hi-Z) and lets go of the wire entirely, so
# another buffer can drive it.  With a one-hot select (exactly one enable high
# at a time) several sources take turns owning the same bus line -- no shorts,
# no software, just electrical release.
#
# Here two sources -- the constant word 0b01 and the constant word 0b10 -- are
# gated onto a shared 2-bit bus by tri-state buffers.  A select line chooses
# which source drives; a weak pull-down keeps the bus defined when neither does.
#
#   run with:  tclsh examples/tristate_bus.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]

set s [schem::new tristate_bus]
$s add battery VCC -emf 12 ; $s add ground GND ; $s wire VCC.neg GND.t

# SEL high -> source 1 drives the bus; SEL low -> source 0 drives it.  An
# inverter relay gives us SEL's complement to enable the other bank.
$s add switch SEL -state open ; $s wire VCC.pos SEL.a
$s add relay INV -coil 1000 ; $s wire SEL.b INV.c1 ; $s wire INV.c2 GND.t
$s wire VCC.pos INV.com                      ;# NC (SEL low) -> /SEL high
set nsel INV.nc                               ;# /SEL: high when SEL is low

# the shared bus lines (a junction per bit) + a weak pull-down bus keeper
foreach i {0 1} {
    $s add junction BUS$i
    $s add resistor K$i -r 100000 ; $s wire BUS$i.t K$i.a ; $s wire K$i.b GND.t
}

# Two source words gated onto the bus.  src0 = 0b01, src1 = 0b10; bit i of each
# source is driven onto BUS bit i by a tri-state buffer enabled with its bank.
foreach {bank enable bits} [list 0 $nsel {1 0}  1 SEL.b {0 1}] {
    set i 0
    foreach bit $bits {
        $s add buffer G${bank}_$i
        if {$bit} { $s wire VCC.pos G${bank}_${i}.in }   ;# in = 1 (else floats low)
        $s wire $enable G${bank}_${i}.oe                 ;# enable this bank
        $s wire G${bank}_${i}.out BUS$i.t                ;# tie onto the shared bus
        incr i
    }
}

proc busval {s} {
    set v 0
    foreach i {0 1} { if {[$s probe BUS$i.t] > 6} { set v [expr {$v | (1 << $i)}] } }
    return $v
}

$s open SEL  ; $s solve ; puts "SEL=0 -> bus = [busval $s]   (source0 = 0b01 = 1)"
$s close SEL ; $s solve ; puts "SEL=1 -> bus = [busval $s]   (source1 = 0b10 = 2)"
puts "(one bus, two talkers -- whichever is enabled owns the wires)"
