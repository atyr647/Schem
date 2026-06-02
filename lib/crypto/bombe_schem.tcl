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

package require Tcl 8.6-
namespace eval ::bombe {}

# build -- the schematic for one candidate setting.  edges: menu; perms: dict
# offset->perm for this candidate; test: central letter; seedWire: 0..25.
#
# The board is organised into named PANELS, carried as a '/' prefix on every
# bundle (the same separator instancing uses).  This gives the schematic real
# hierarchy depth, so semantic zoom has a coarse-to-fine story to tell:
#
#   POWER/   the supply rail and the stiff seed drive
#   MENU/    the 18 letter-cables, the scramblers and the diagonal board
#   REG/     the test register's pull-downs
#   LAMPS/   the 26-bulb stop panel
#
# At the grid level the whole bombe reads as POWER | MENU | REG | LAMPS; zoom
# in and MENU opens into its cables, then each cable into its 26 conductors.
proc ::bombe::build {edges perms test seedWire {name bombe}} {
    set s [::schem::new $name]
    set letters [::bombe::letters $edges]

    $s add ground GND
    $s add battery POWER/PWR -emf 12
    $s wire POWER/PWR.neg GND.t

    # MENU panel: one 26-lane cable per menu letter.
    foreach l $letters { $s bus MENU/CAB_$l 26 }

    # Scrambler edges: cable a lane w  <->  cable b lane S(w).
    foreach e $edges {
        lassign $e off a b
        set P [dict get $perms $off]
        $s repeat w 0 25 {
            set pw [::enigma::ord [string index $P $w]]
            $s connect MENU/CAB_${a}\[$w\] -> MENU/CAB_${b}\[$pw\]
        }
    }

    # Welchman diagonal board: cable a lane ord(b) <-> cable b lane ord(a).
    foreach a $letters {
        set ao [::enigma::ord $a]
        foreach b $letters {
            if {$b <= $a} continue
            set bo [::enigma::ord $b]
            $s connect MENU/CAB_${a}\[$bo\] -> MENU/CAB_${b}\[$ao\]
        }
    }

    # REG panel: pull every test-cable lane down so an un-energised lane reads
    # ~0 V, and expose the lanes as T0..T25 for probing.
    $s bank REG/PD 26 of resistor -r 1e6
    $s connect MENU/CAB_${test}\[*\] -> REG/PD\[*\].a
    $s connect REG/PD\[*\].b -> GND.t
    $s repeat w 0 25 { $s expose T$w [$s lane MENU/CAB_$test $w] }

    # POWER panel: stiff seed drive -- a near-ideal conductor from the supply
    # onto the seed lane, so the whole live cluster sits at the full rail
    # regardless of size.
    $s add resistor POWER/RIN -r 1e-3
    $s wire POWER/PWR.pos POWER/RIN.a
    $s wire POWER/RIN.b [$s lane MENU/CAB_$test $seedWire]

    return $s
}

# addLamps -- the LAMPS panel: 26 indicator bulbs, one per test-cable lane.
# Built as a bank and wired with connect, so it reads like the hardware
# lampboard.
proc ::bombe::addLamps {s test} {
    $s bank LAMPS/L_T 26 of lamp -r 2000 -ion 0.0005
    $s repeat w 0 25 { $s connect [$s port T$w] -> LAMPS/L_T\[$w\].a }
    $s connect LAMPS/L_T\[*\].b -> GND.t
    set lamps {} ; for {set w 0} {$w < 26} {incr w} { lappend lamps LAMPS/L_T#$w }
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
    for {set w 0} {$w < 26} {incr w} { if {[$s lit LAMPS/L_T#$w]} { lappend on $w } }
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
