# lib/standard.tcl --
#
# The standard panel circuits: the named building blocks an electrician
# reaches for -- time-delay relays, a one-shot, a contact debounce, a
# flasher and a latching relay bank.  Every one is an ordinary electrical
# circuit (coils, contacts, resistors, capacitors), and every behaviour is
# computed by the engine from Ohm's and Kirchhoff's laws and the device
# rules -- nothing here is a logic abstraction.
#
# Timing comes from real RC charge/discharge against a relay's pick-up and
# drop-out current, so the time-based cells are observed with the transient
# analyser (`run`), driving their inputs with a timed stimulus
# (`run -events {t {close IN} ...}`), exactly as you would operate a panel.
#
# Conventions (same rails as the logic library):
#   VCC / GND  supply rails (exposed)
#   IN         the control input: tie to VCC through a contact to "energise"
#   OUT        a clean output level: ~VCC while the cell's relay is picked up

namespace eval ::schem::lib {
    variable TCOIL 100.0     ;# timing-relay coil resistance (ohms)
    variable TPICK 0.05      ;# pick-up current (amps) -> 5 V across the coil
    variable TDROP 0.04      ;# drop-out current (amps): a modest hysteresis
    variable TPULL 10000.0   ;# output pull-down (ohms)
}

# TRails -- supply rails plus the timing relay TR and its clean output OUT.
# Leaves TR.c1 as the coil-drive node for the timing network to feed.
proc ::schem::lib::TRails {c} {
    variable TCOIL ; variable TPICK ; variable TDROP ; variable TPULL
    $c add junction VR ; $c add junction GR
    $c expose VCC VR.t ; $c expose GND GR.t
    $c add relay TR -coil $TCOIL -pickup $TPICK -dropout $TDROP
    $c wire TR.c2 GR.t
    $c wire VR.t TR.com
    $c add resistor PD -r $TPULL
    $c wire TR.no PD.a ; $c wire PD.b GR.t
    $c expose OUT PD.a
    $c expose NC  TR.nc      ;# the break contact, for normally-on loads
}

# on_delay_timer (TON) -- when IN is energised the output picks up only
# after a delay set by R*C: IN charges a capacitor through R, and TR closes
# when the coil current reaches pick-up.  Ports: IN OUT NC VCC GND.
proc ::schem::lib::on_delay_timer {{name ton} {R 100.0} {C 5e-5}} {
    set c [::schem::circuit $name]
    TRails $c
    $c add resistor RT -r $R
    $c add capacitor CT -c $C
    $c expose IN RT.a
    $c wire RT.b TR.c1
    $c wire TR.c1 CT.a ; $c wire CT.b GR.t   ;# tank capacitor across the coil
    return $c
}

# off_delay_timer (TOFF) -- the output picks up at once when IN energises,
# and stays up for a while after IN drops.  A diode charges the tank fast;
# when IN falls the diode blocks and the capacitor holds the coil up until
# it bleeds below drop-out (delay set by C against the coil).
# Ports: IN OUT NC VCC GND.
proc ::schem::lib::off_delay_timer {{name toff} {C 1e-4}} {
    set c [::schem::circuit $name]
    TRails $c
    $c add diode DD
    $c add capacitor CT -c $C
    $c expose IN DD.a
    $c wire DD.k TR.c1
    $c wire TR.c1 CT.a ; $c wire CT.b GR.t
    return $c
}

# one_shot (monostable) -- a rising edge on IN produces a single output
# pulse of fixed width, no matter how long IN stays up.  IN is capacitively
# coupled into the coil through a diode, so only the rising edge drives it;
# as the coupling capacitor charges the coil current decays below drop-out
# and the pulse ends.  R bleeds the capacitor so it re-arms when IN falls.
# Pulse width ~ R*C.  Ports: IN OUT NC VCC GND.
proc ::schem::lib::one_shot {{name oneshot} {R 200.0} {C 5e-5}} {
    set c [::schem::circuit $name]
    TRails $c
    $c add capacitor CC -c $C
    $c add diode DD
    $c add resistor RB -r $R
    $c expose IN CC.a
    $c wire CC.b DD.a
    $c wire DD.k TR.c1            ;# diode: only the forward (rising) surge drives TR
    $c wire TR.c1 RB.a ; $c wire RB.b GR.t
    $c add resistor RBLEED -r $R
    $c wire CC.b RBLEED.a ; $c wire RBLEED.b GR.t   ;# re-arm path for the coupling cap
    return $c
}

# debounce -- an RC contact filter.  A bouncing input contact chatters, but
# the capacitor integrates the chatter so the relay sees one clean rise and
# the output makes a single, solid transition.  Ports: IN OUT NC VCC GND.
proc ::schem::lib::debounce {{name debounce} {R 100.0} {C 1e-4}} {
    set c [::schem::circuit $name]
    TRails $c
    $c add resistor RT -r $R
    $c add capacitor CT -c $C
    $c expose IN RT.a
    $c wire RT.b TR.c1
    $c wire TR.c1 CT.a ; $c wire CT.b GR.t
    return $c
}

# flasher (astable) -- a free-running pulse generator: the classic
# self-interrupting relay.  The coil is fed through the relay's own break
# (NC) contact, so energising the coil opens that contact, which drops the
# coil, which closes the contact again -- forever.  OUT (the make contact)
# pulses on and off with no external clock; the rate is the relay's own
# switching cadence.  Ports: OUT VCC GND.
proc ::schem::lib::flasher {{name flasher}} {
    variable TCOIL ; variable TPICK ; variable TDROP ; variable TPULL
    set c [::schem::circuit $name]
    $c add junction VR ; $c add junction GR
    $c expose VCC VR.t ; $c expose GND GR.t
    $c add relay FL -coil $TCOIL -pickup $TPICK -dropout $TDROP
    # VCC -> FL.com -> FL.nc (break) -> coil(c1): self-interrupting feedback.
    $c wire VR.t FL.com
    $c wire FL.nc FL.c1
    $c wire FL.c2 GR.t
    # OUT taps the make contact: live while the relay is picked up.
    $c add resistor PD -r $TPULL
    $c wire FL.no PD.a ; $c wire PD.b GR.t
    $c expose OUT PD.a
    return $c
}

# relay_bank -- a latching annunciator bank: `n` independent seal-in
# channels sharing one common RESET.  Pressing SET<i> latches channel i
# (Q<i> stays high via its own hold contact); opening the common RST
# (a normally-closed switch in the coils' return) drops every channel at
# once.  Ports: Q1..Qn VCC GND  (operate SET1..SETn buttons, RST switch).
proc ::schem::lib::relay_bank {{name bank} {n 3}} {
    variable TCOIL ; variable TPICK
    set c [::schem::circuit $name]
    $c add junction VR ; $c add junction GR
    $c expose VCC VR.t ; $c expose GND GR.t
    $c add switch RST -state closed         ;# common reset: open to clear the bank
    $c wire RST.b GR.t                       ;# coils return to ground through RST
    for {set i 1} {$i <= $n} {incr i} {
        $c add relay  K$i   -coil $TCOIL -pickup $TPICK
        $c add button SET$i
        $c wire VR.t SET$i.a                 ;# VCC -> SETi
        $c wire SET$i.b K$i.c1               ;# set energises the coil
        $c wire VR.t K$i.com                 ;# seal: VCC -> own make contact -> coil
        $c wire K$i.no K$i.c1
        $c wire K$i.c2 RST.a                 ;# coil return via the common reset
        $c expose Q$i K$i.c1
    }
    return $c
}

# safety_interlock -- the classic start/stop motor-control interlock with a
# guard chain.  A momentary START seals in the run contactor RUN through its
# own make contact; the machine keeps running until STOP (a normally-closed
# button) is pressed.  In series with the hold are `n` guard switches and an
# emergency-stop, all normally-closed: if *any* guard opens (or E-STOP is
# hit) the seal breaks and RUN drops instantly -- a logical AND of "all
# guards in place" gating the run latch.  RUN is HIGH while the machine runs.
# Ports: RUN VCC GND  (operate START button, STOP button, ESTOP switch,
# GUARD1..GUARDn switches on the instantiated cell).
proc ::schem::lib::safety_interlock {{name interlock} {n 2}} {
    variable TCOIL ; variable TPICK ; variable TDROP
    set c [::schem::circuit $name]
    $c add junction VR ; $c add junction GR
    $c expose VCC VR.t ; $c expose GND GR.t
    $c add relay  RUN   -coil $TCOIL -pickup $TPICK -dropout $TDROP
    $c add button START                      ;# momentary: energises the coil
    $c add button STOP  -state pressed        ;# N.C. run/stop (pressed = closed)
    $c add switch ESTOP -state closed          ;# N.C. emergency stop
    # Build the normally-closed guard chain: VCC -> ESTOP -> GUARD1 ... -> head.
    $c wire VR.t ESTOP.a
    set head ESTOP.b
    for {set i 1} {$i <= $n} {incr i} {
        $c add switch GUARD$i -state closed
        $c wire $head GUARD$i.a
        set head GUARD$i.b
    }
    # head now carries VCC only when E-STOP and every guard are closed.
    # START and the seal contact both feed the STOP button, then the coil.
    $c wire $head START.a   ; $c wire START.b STOP.a      ;# momentary start
    $c wire $head RUN.com   ; $c wire RUN.no  STOP.a      ;# seal-in (self-hold)
    $c wire STOP.b RUN.c1   ; $c wire RUN.c2  GR.t         ;# through STOP into the coil
    $c expose RUN RUN.c1
    return $c
}
