# lib/logic.tcl --
#
# The relay standard-cell library: logic built entirely from relays, the
# way relay computers did it.  Each cell is a reusable Schem *circuit* (a
# bounded group of components exposing a terminal contract), so cells
# compose into larger circuits, panels and grids.
#
# Signal convention (active-high):
#   * a logic level is a node voltage -- HIGH ~= VCC, LOW ~= 0 V (GND).
#   * an input drives a relay coil: HIGH energises it.
#   * an output is a node tied to VCC through contacts when HIGH, and to
#     GND through a pull-down resistor when LOW.
# Because outputs are levels and inputs are coils, a cell's OUT drives the
# next cell's input directly -- gates chain with no glue.
#
# Contracts:
#   1-input gate (NOT):           ports  A          OUT  VCC  GND
#   2-input gate (AND/OR/NAND/NOR): ports A  B       OUT  VCC  GND
#   sr_latch:                      ports  Q          VCC  GND   (+ SET button, RST switch)
#
# The gate truth tables follow from contact topology, not from any "if":
#   AND   NO contacts in series        OR    NO contacts in parallel
#   NAND  NC contacts in parallel      NOR   NC contacts in series
#   NOT   one NC contact

namespace eval ::schem::lib {
    variable COIL 100.0     ;# relay coil resistance (ohms)
    variable PICK 0.01      ;# coil pick-up current (amps)
    variable PULL 10000.0   ;# output pull-down (ohms) -- defines the LOW level
}

# Rails -- add VCC/GND rail junctions to a cell and expose them.
proc ::schem::lib::Rails {c} {
    $c add junction VR
    $c add junction GR
    $c expose VCC VR.t
    $c expose GND GR.t
}

# Coil -- add a relay whose coil is driven by exposed input port `port`.
proc ::schem::lib::Coil {c relay port} {
    variable COIL ; variable PICK
    $c add relay $relay -coil $COIL -pickup $PICK
    $c wire $relay.c2 GR.t
    $c expose $port $relay.c1
}

# Pulldown -- add the output pull-down and expose OUT at node `term`.
proc ::schem::lib::Pulldown {c term} {
    variable PULL
    $c add resistor PD -r $PULL
    $c wire $term PD.a
    $c wire PD.b GR.t
    $c expose OUT PD.a
}

proc ::schem::lib::not_gate {{name not}} {
    set c [::schem::circuit $name]
    Rails $c
    Coil $c K A
    $c wire VR.t K.com            ;# VCC into common
    Pulldown $c K.nc              ;# OUT = NC: HIGH only when de-energised
    return $c
}

proc ::schem::lib::and_gate {{name and}} {
    set c [::schem::circuit $name]
    Rails $c
    Coil $c KA A ; Coil $c KB B
    $c wire VR.t KA.com           ;# VCC -> KA.NO -> KB.NO -> OUT (series)
    $c wire KA.no KB.com
    Pulldown $c KB.no
    return $c
}

proc ::schem::lib::or_gate {{name or}} {
    set c [::schem::circuit $name]
    Rails $c
    Coil $c KA A ; Coil $c KB B
    $c wire VR.t KA.com ; $c wire VR.t KB.com   ;# NO contacts in parallel
    $c add resistor PD -r $::schem::lib::PULL
    $c wire KA.no PD.a ; $c wire KB.no PD.a
    $c wire PD.b GR.t
    $c expose OUT PD.a
    return $c
}

proc ::schem::lib::nand_gate {{name nand}} {
    set c [::schem::circuit $name]
    Rails $c
    Coil $c KA A ; Coil $c KB B
    $c wire VR.t KA.com ; $c wire VR.t KB.com   ;# NC contacts in parallel
    $c add resistor PD -r $::schem::lib::PULL
    $c wire KA.nc PD.a ; $c wire KB.nc PD.a
    $c wire PD.b GR.t
    $c expose OUT PD.a
    return $c
}

proc ::schem::lib::nor_gate {{name nor}} {
    set c [::schem::circuit $name]
    Rails $c
    Coil $c KA A ; Coil $c KB B
    $c wire VR.t KA.com           ;# NC contacts in series
    $c wire KA.nc KB.com
    Pulldown $c KB.nc
    return $c
}

# Fan -- add an input junction that distributes a port to several
# sub-instance input terminals, and expose it as `port`.
proc ::schem::lib::Fan {c port jn targets} {
    $c add junction $jn
    foreach t $targets { $c wire $jn.t $t }
    $c expose $port $jn.t
}

# RailUp -- wire a sub-instance's VCC/GND ports to this cell's rails.
proc ::schem::lib::RailUp {c portmap} {
    $c wire [dict get $portmap VCC] VR.t
    $c wire [dict get $portmap GND] GR.t
}

# xor_gate -- A XOR B = AND(OR(A,B), NAND(A,B)).  Composed from primitives.
proc ::schem::lib::xor_gate {{name xor}} {
    set c [::schem::circuit $name]
    Rails $c
    set OR [$c instantiate [or_gate]   OR]
    set ND [$c instantiate [nand_gate] ND]
    set AN [$c instantiate [and_gate]  AN]
    foreach pm [list $OR $ND $AN] { RailUp $c $pm }
    Fan $c A IA [list [dict get $OR A] [dict get $ND A]]
    Fan $c B IB [list [dict get $OR B] [dict get $ND B]]
    $c wire [dict get $OR OUT] [dict get $AN A]
    $c wire [dict get $ND OUT] [dict get $AN B]
    $c expose OUT [dict get $AN OUT]
    return $c
}

# half_adder -- SUM = A XOR B, CARRY = A AND B.
proc ::schem::lib::half_adder {{name hadd}} {
    set c [::schem::circuit $name]
    Rails $c
    set X [$c instantiate [xor_gate] X]
    set A [$c instantiate [and_gate] C]
    RailUp $c $X ; RailUp $c $A
    Fan $c A IA [list [dict get $X A] [dict get $A A]]
    Fan $c B IB [list [dict get $X B] [dict get $A B]]
    $c expose SUM   [dict get $X OUT]
    $c expose CARRY [dict get $A OUT]
    return $c
}

# full_adder -- SUM = A^B^Cin, COUT = AB + Cin(A^B).  Two half-adders + OR.
proc ::schem::lib::full_adder {{name fadd}} {
    set c [::schem::circuit $name]
    Rails $c
    set H1 [$c instantiate [half_adder] H1]
    set H2 [$c instantiate [half_adder] H2]
    set OR [$c instantiate [or_gate]    O]
    RailUp $c $H1 ; RailUp $c $H2 ; RailUp $c $OR
    Fan $c A   IA [list [dict get $H1 A]]
    Fan $c B   IB [list [dict get $H1 B]]
    Fan $c CIN IC [list [dict get $H2 B]]
    $c wire [dict get $H1 SUM]   [dict get $H2 A]
    $c wire [dict get $H1 CARRY] [dict get $OR A]
    $c wire [dict get $H2 CARRY] [dict get $OR B]
    $c expose SUM  [dict get $H2 SUM]
    $c expose COUT [dict get $OR OUT]
    return $c
}

# sr_latch -- a seal-in (self-holding) relay latch: a 1-bit memory.
# Pressing SET energises the coil, whose own NO contact then keeps it
# energised after SET is released; opening the normally-closed RST switch
# drops it.  Q is HIGH while latched.  Ports: VCC GND Q; operate SET (a
# button) and RST (a switch) on the instantiated cell.
proc ::schem::lib::sr_latch {{name latch}} {
    variable COIL ; variable PICK
    set c [::schem::circuit $name]
    Rails $c
    $c add relay  K -coil $COIL -pickup $PICK
    $c add button SET
    $c add switch RST -state closed
    # VCC -> SET --\
    #               +-- node J -- RST(NC) -- coil(K.c1)
    # VCC -> K.NO --/   (seal)
    $c wire VR.t SET.a ; $c wire SET.b RST.a
    $c wire VR.t K.com ; $c wire K.no RST.a       ;# seal contact onto J
    $c wire RST.b K.c1 ; $c wire K.c2 GR.t
    $c expose Q K.c1
    return $c
}
