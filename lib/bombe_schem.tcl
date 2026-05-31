# lib/bombe_schem.tcl --
#
# The Bombe as an actual Schem schematic, built from bundled conductors -- the
# language artifact, not a simulation of one.  A stop is an electrical closure
# the engine finds by merging connected nodes, read off an indicator lamp.
#
# The board now reads like an electrician's print, thanks to the bus/bank/
# connect drafting layer:
#
#   * Each menu letter is a 26-lane BUS (its cable) -- 26 real conductors.
#   * Each menu edge is a scrambler: 26 patch wires joining cable A lane w to
#     cable B lane S(w), S the Enigma scrambler permutation at that offset's
#     rotor position (an involution, so plain bidirectional copper).
#   * Welchman's diagonal board: cable a lane ord(b) tied to cable b lane
#     ord(a), in copper.
#   * The test register's lanes each pull down through a resistor, and a BANK
#     of 26 lamps reads the register -- the panel the operator watched.  A
#     stiff seed drive holds every wire continuity ties to the seed at the full
#     rail, so a single-live stop lights one bulb and a single-dead (dual) stop
#     lights twenty-five, the lone dark bulb naming the deduced stecker.
#
# Construction (which lanes to patch) is drafting-time arithmetic; the board it
# leaves behind is pure Schem and round-trips through the binary .schem file.

package require Tcl 8.6
namespace eval ::bombe {}

# build -- the schematic for one candidate setting.  edges: menu; perms: dict
# offset->perm for this candidate; test: central letter; seedWire: 0..25.
proc ::bombe::build {edges perms test seedWire {name bombe}} {
    set s [::schem::new $name]
    set letters [::bombe::letters $edges]

    $s add ground GND
    $s add battery PWR -emf 12
    $s wire PWR.neg GND.t

    # One 26-lane cable per menu letter.
    foreach l $letters { $s bus CAB_$l 26 }

    # Scrambler edges: cable a lane w  <->  cable b lane S(w).
    foreach e $edges {
        lassign $e off a b
        set P [dict get $perms $off]
        $s repeat w 0 25 {
            set pw [::enigma::ord [string index $P $w]]
            $s connect CAB_${a}\[$w\] -> CAB_${b}\[$pw\]
        }
    }

    # Welchman diagonal board: cable a lane ord(b) <-> cable b lane ord(a).
    foreach a $letters {
        set ao [::enigma::ord $a]
        foreach b $letters {
            if {$b <= $a} continue
            set bo [::enigma::ord $b]
            $s connect CAB_${a}\[$bo\] -> CAB_${b}\[$ao\]
        }
    }

    # Test register: pull every lane down so an un-energised lane reads ~0 V,
    # and expose the lanes as T0..T25 for probing.
    $s bank PD 26 of resistor -r 1e6
    $s connect CAB_${test}\[*\] -> PD\[*\].a
    $s connect PD\[*\].b -> GND.t
    $s repeat w 0 25 { $s expose T$w [$s lane CAB_$test $w] }

    # Stiff seed drive: a near-ideal conductor from the supply onto the seed
    # lane, so the whole live cluster sits at the full rail regardless of size.
    $s add resistor RIN -r 1e-3
    $s wire PWR.pos RIN.a
    $s wire RIN.b [$s lane CAB_$test $seedWire]

    return $s
}

# addLamps -- the panel of 26 indicator bulbs, one per test-cable lane.  Built
# as a bank and wired with connect, so it reads like the hardware lampboard.
proc ::bombe::addLamps {s test} {
    $s bank L_T 26 of lamp -r 2000 -ion 0.0005
    $s repeat w 0 25 { $s connect [$s port T$w] -> L_T\[$w\].a }
    $s connect L_T\[*\].b -> GND.t
    set lamps {} ; for {set w 0} {$w < 26} {incr w} { lappend lamps L_T#$w }
    return $lamps
}

# liveWires -- after solving, the test-cable lanes that are HIGH.
proc ::bombe::liveWires {s {thr 6.0}} {
    set live {}
    foreach {pn term} [$s ports] {
        if {![string match T* $pn]} continue
        if {[$s probe $term] > $thr} { lappend live [string range $pn 1 end] }
    }
    return [lsort -integer $live]
}

# litLamps -- which readout lamps are glowing.
proc ::bombe::litLamps {s} {
    set on {}
    for {set w 0} {$w < 26} {incr w} { if {[$s lit L_T#$w]} { lappend on $w } }
    return $on
}

# stopLamp -- read the panel as the machine did: a stop is "not all 26 bulbs
# the same".  Returns the deduced stecker lane (0..25) on a stop, else -1.
proc ::bombe::stopLamp {s} {
    set lit [::bombe::litLamps $s]
    set n [llength $lit]
    if {$n == 1}  { return [lindex $lit 0] }
    if {$n == 25} { for {set w 0} {$w < 26} {incr w} { if {$w ni $lit} { return $w } } }
    return -1
}

package provide bombe_schem 1.0
