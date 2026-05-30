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

# ====================================================================
#  Clocked (sequential) logic -- the level latch gains a clock.
# ====================================================================
#
# The sr_latch above is level memory.  A *clocked* cell only samples its
# data when a clock permits it; chaining two oppositely-gated latches
# (master / slave) makes the cell edge-triggered, and edge-triggering is
# what lets flip-flops chain into a counter without racing.  These cells
# are still nothing but relay contacts -- the clock is just another coil.

# d_latch -- a gated (level-sensitive) D latch.  Ports: D CLK Q OUT NQ VCC GND.
# `gate` selects clock polarity: "no" = transparent while CLK HIGH (the
# default), "nc" = transparent while CLK LOW (used for a master stage).
#
# Topology (all relay contacts, no "if"):
#   clock gate   VCC -> KC.<gate> -> KD.com            (data only passes when gated)
#   set   (CLK&D)   KD.no  -> KL.c1                     (energise the latch)
#   reset (CLK&~D)  KD.nc  -> KR.coil                   (a reset-detect relay)
#   seal  (hold)  VCC -> KL.no -> KR.nc -> KL.c1        (self-hold unless resetting)
#   Q  = KL.c1 (coil node: ~VCC latched, ~0 idle);  NQ = KL's free NC contact.
proc ::schem::lib::d_latch {{name dlatch} {gate no}} {
    variable COIL ; variable PICK ; variable PULL
    set c [::schem::circuit $name]
    Rails $c
    foreach r {KC KD KR KL} {
        $c add relay $r -coil $COIL -pickup $PICK
        $c wire $r.c2 GR.t
    }
    $c expose CLK KC.c1
    $c expose D   KD.c1
    # Clock gate: VCC reaches the data contact only through KC's chosen throw.
    $c wire VR.t KC.com
    $c wire KC.$gate KD.com
    # Set path (gate AND D): drive the latch coil node directly.
    $c wire KD.no KL.c1
    # Reset detect (gate AND ~D): energise KR, whose NC contact breaks the seal.
    $c wire KD.nc KR.c1
    # Seal-in hold path, interrupted by KR during a reset.
    $c wire VR.t KL.com
    $c wire KL.no KR.com
    $c wire KR.nc KL.c1
    # Outputs: Q is the latch coil node; NQ comes from KL's spare NC contact.
    $c expose Q   KL.c1
    $c expose OUT KL.c1
    $c add resistor PN -r $PULL
    $c wire KL.nc PN.a ; $c wire PN.b GR.t
    $c expose NQ PN.a
    return $c
}

# d_flipflop -- a rising-edge-triggered D flip-flop (master/slave).  The
# master latch is transparent while CLK is LOW (so it tracks D); the slave
# is transparent while CLK is HIGH.  On the rising edge the master freezes
# the value it last saw and the slave copies it -- so Q takes D's value at
# the clock edge and is immune to D changing afterwards.
# Ports: D CLK Q NQ VCC GND.
proc ::schem::lib::d_flipflop {{name dff}} {
    set c [::schem::circuit $name]
    Rails $c
    set M [$c instantiate [d_latch M nc] M]   ;# master: transparent on CLK low
    set S [$c instantiate [d_latch S no] S]   ;# slave:  transparent on CLK high
    RailUp $c $M ; RailUp $c $S
    Fan $c CLK ICK [list [dict get $M CLK] [dict get $S CLK]]
    $c expose D [dict get $M D]
    $c wire [dict get $M Q] [dict get $S D]   ;# master Q feeds slave D
    $c expose Q  [dict get $S Q]
    $c expose NQ [dict get $S NQ]
    return $c
}

# t_flipflop -- a toggle flip-flop: Q inverts on every rising clock edge.
# It is just a D flip-flop with D wired back to its own ~Q.  Ports: CLK Q NQ.
proc ::schem::lib::t_flipflop {{name tff}} {
    set c [::schem::circuit $name]
    Rails $c
    set FF [$c instantiate [d_flipflop FF] FF]
    RailUp $c $FF
    $c wire [dict get $FF NQ] [dict get $FF D]   ;# D <- ~Q : toggle each edge
    $c expose CLK [dict get $FF CLK]
    $c expose Q   [dict get $FF Q]
    $c expose NQ  [dict get $FF NQ]
    return $c
}

# counter2 -- a 2-bit asynchronous (ripple) binary counter.  Stage 0 toggles
# on the external clock; stage 1 is clocked by stage 0's ~Q, so it advances
# when bit 0 falls (1 -> 0).  The count Q1Q0 runs 00,01,10,11,00,...
# Ports: CLK Q0 Q1 VCC GND.
proc ::schem::lib::counter2 {{name cnt2}} {
    set c [::schem::circuit $name]
    Rails $c
    set F0 [$c instantiate [t_flipflop F0] F0]
    set F1 [$c instantiate [t_flipflop F1] F1]
    RailUp $c $F0 ; RailUp $c $F1
    $c expose CLK [dict get $F0 CLK]
    $c wire [dict get $F0 NQ] [dict get $F1 CLK]   ;# ripple: stage 1 <- ~Q0
    $c expose Q0 [dict get $F0 Q]
    $c expose Q1 [dict get $F1 Q]
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
