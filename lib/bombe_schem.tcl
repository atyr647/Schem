# lib/bombe_schem.tcl --
#
# The Bombe as an actual Schem schematic -- the language artifact, not a
# simulation of one.  Given a menu and a candidate rotor setting, this wires a
# real board the engine then *solves*: the stop is read off an indicator LAMP
# that the engine lights from its own continuity, exactly as the hardware lit
# its relays.
#
# Construction (all parts, no abstraction):
#   * One 26-wire cable per menu letter, built from a junction per wire so many
#     conductors can share a node (the bombe's 26-way commoning).
#   * Each menu edge is a scrambler: 26 ideal wires joining cable A's wire w to
#     cable B's wire P(w), P being the Enigma scrambler permutation at that
#     offset's rotor position (plugboard removed).  An involution, so the cable
#     is bidirectional -- plain copper.
#   * Welchman's diagonal board: cable a's wire ord(b) tied to cable b's wire
#     ord(a), in copper.
#   * A test battery energises one wire of the test cable through a current-
#     limiting resistor; every wire is pulled to ground through its own high
#     resistance, so a wire sits HIGH only if continuity ties it to the live
#     seed.  A LAMP across the seed wire's neighbour shows the register state.
#
# We expose the test cable's 26 wires as ports T0..T25 and put a lamp on a
# chosen readout wire, so a caller can both probe the register and *see* a
# stop.  A correct stop leaves a single wire live; we light a lamp wired to
# detect the single-live condition on the deduced stecker wire.

package require Tcl 8.6
namespace eval ::bombe {}

# build -- construct the schematic for one candidate setting.  Returns the
# schematic; the caller solves it and reads `live` / the stop lamp.
#   edges    : menu from ::bombe::menu
#   perms    : dict offset->perm from ::bombe::scramblerPerms (this candidate)
#   test     : central letter ; seedWire : which wire to energise (0..25)
proc ::bombe::build {edges perms test seedWire {name bombe}} {
    set s [::schem::new $name]
    set letters [::bombe::letters $edges]

    $s add ground GND
    $s add battery PWR -emf 12
    $s wire PWR.neg GND.t

    # A junction per (letter,wire): the shared node every conductor on that
    # wire attaches to.  Name: J_<letter><wire>.
    foreach l $letters {
        for {set w 0} {$w < 26} {incr w} {
            $s add junction J_${l}$w
        }
    }

    # Scrambler edges: cable a wire w  <->  cable b wire P(w).
    foreach e $edges {
        lassign $e off a b
        set P [dict get $perms $off]
        for {set w 0} {$w < 26} {incr w} {
            set pw [::enigma::ord [string index $P $w]]
            $s wire J_${a}${w}.t J_${b}${pw}.t
        }
    }

    # Welchman diagonal board.
    foreach a $letters {
        set ao [::enigma::ord $a]
        foreach b $letters {
            if {$b <= $a} continue
            set bo [::enigma::ord $b]
            $s wire J_${a}${bo}.t J_${b}${ao}.t
        }
    }

    # Pull every wire of the test cable down through its own resistor, so an
    # un-energised wire reads ~0 V and only continuity to the seed lifts it.
    for {set w 0} {$w < 26} {incr w} {
        $s add resistor PD_$w -r 1e6
        $s wire J_${test}${w}.t PD_${w}.a
        $s wire PD_${w}.b GND.t
        $s expose T$w J_${test}${w}.t
    }

    # Energise the seed wire through a limiting resistor.
    $s add resistor RIN -r 1000
    $s wire PWR.pos RIN.a
    $s wire RIN.b J_${test}${seedWire}.t

    return $s
}

# liveWires -- after solving, which test-cable wires are HIGH (continuity to
# the live seed).  Threshold at half the supply.
proc ::bombe::liveWires {s {thr 6.0}} {
    set live {}
    foreach {pn term} [$s ports] {
        if {![string match T* $pn]} continue
        if {[$s probe $term] > $thr} { lappend live [string range $pn 1 end] }
    }
    return [lsort -integer $live]
}

# stopLamp -- add a "stop" indicator that lights on a correct stop.  A stop
# leaves a single test-cable wire dead (the deduced non-self-stecker) or single
# live; the simplest faithful readout is a lamp on each test wire -- the panel
# of 26 bulbs the operator watched.  We add them as L_T0..L_T25, each lit when
# its wire is HIGH, and return their names.  On a stop, all but one are lit (or
# only one is) -- the odd bulb out is the answer.
proc ::bombe::addLamps {s test} {
    set lamps {}
    for {set w 0} {$w < 26} {incr w} {
        set t [$s port T$w]
        $s add lamp L_T$w -r 2000 -ion 0.0005
        $s wire $t L_T${w}.a
        $s wire L_T${w}.b GND.t
        lappend lamps L_T$w
    }
    return $lamps
}

# litLamps -- after solving, which readout lamps are glowing.
proc ::bombe::litLamps {s} {
    set on {}
    for {set w 0} {$w < 26} {incr w} {
        if {[$s lit L_T$w]} { lappend on $w }
    }
    return $on
}

package provide bombe_schem 1.0
