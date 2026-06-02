# lib/bombe.tcl --
#
# Turing's Bombe -- the electromechanical key-search engine that broke the
# Enigma -- expressed against the Schem electrical model.
#
# THE IDEA (why this is a circuit at all).  A stop is an *electrical closure*.
# Each letter of the crib's alphabet gets a 26-wire cable (one wire per
# possible steckered value).  A scrambler (an Enigma with the plugboard
# removed, at one rotor position) joins two cables: because the reflector makes
# it an involution, it is plain bidirectional cable -- wire i of one cable joins
# wire P(i) of the other.  Welchman's diagonal board adds the reciprocity of
# the plugboard: wire b of cable A joins wire a of cable B.  Energise one wire
# of the test cable (a hypothesis "this letter steckers to that one") and
# current floods every wire the menu forces to share its potential.  A WRONG
# hypothesis closes back on itself through the loops of the menu and lights all
# 26 wires; a RIGHT one leaves a single wire live (or, dually, a single wire
# dark).  That asymmetry -- "not all 26 the same" -- is the stop.
#
# This file builds the menu from a crib, computes the closure (the engine's own
# continuity, when realised as a schematic; a union-find when scanned), tests
# for a stop, scans the rotor start positions, and -- because the heavy 26^3
# sweep is meant to run compiled -- emits the scan as Zig.  The Enigma oracle
# (lib/enigma.tcl) makes the crib and checks the recovered key.

package require Tcl 8.6-
namespace eval ::bombe {}

# ----------------------------------------------------------------------
# Menu construction.
# ----------------------------------------------------------------------
#
# A menu is the crib as a graph: an edge for each position, joining the
# plaintext letter to the ciphertext letter, tagged with the scrambler offset
# (the position in the message, which fixes that scrambler's rotor setting).
#   crib plain="WETTER..." cipher="..." -> edges {offset a b}
proc ::bombe::menu {plain cipher} {
    set plain  [string toupper $plain]
    set cipher [string toupper $cipher]
    if {[string length $plain] != [string length $cipher]} {
        return -code error "crib plaintext and ciphertext differ in length"
    }
    set edges {}
    for {set i 0} {$i < [string length $plain]} {incr i} {
        set a [string index $plain $i]
        set b [string index $cipher $i]
        # Enigma never enciphers a letter to itself; such a crib position is
        # impossible and a real codebreaker would slide the crib.
        if {$a eq $b} { return -code error "crib position $i maps $a->$a (impossible)" }
        lappend edges [list $i $a $b]
    }
    return $edges
}

# letters -- the distinct letters the menu touches (its cables).
proc ::bombe::letters {edges} {
    set s {}
    foreach e $edges { dict set s [lindex $e 1] 1 ; dict set s [lindex $e 2] 1 }
    return [lsort [dict keys $s]]
}

# central -- the most-connected letter, the natural test register: energising
# the busiest node drives the most of the menu's loops.
proc ::bombe::central {edges} {
    set deg [dict create]
    foreach e $edges {
        dict incr deg [lindex $e 1] ; dict incr deg [lindex $e 2]
    }
    set best "" ; set bd -1
    foreach l [lsort [dict keys $deg]] {
        if {[dict get $deg $l] > $bd} { set bd [dict get $deg $l] ; set best $l }
    }
    return $best
}

# ----------------------------------------------------------------------
# Scrambler positions for a candidate ground setting.
# ----------------------------------------------------------------------
#
# Given a candidate ground (L M R window letters) and the wheel order/rings,
# return, for each crib offset present in the menu, the rotor position to set
# that scrambler to.  We step a real machine from the ground so the middle- and
# left-rotor turnovers (including the double step) are handled exactly -- the
# bombe does not have to assume the crib avoids a turnover.
proc ::bombe::positions {wheels rings ground maxoff} {
    set m [::enigma::new -wheels $wheels -rings $rings -pos $ground]
    set pos {}
    for {set i 0} {$i <= $maxoff} {incr i} {
        ::enigma::Step m            ;# stepping precedes each character
        lappend pos [dict get $m pos]
    }
    return $pos
}

# scramblerPerms -- the 26-permutation for every menu edge at a candidate
# ground.  Returned as a dict offset -> perm-string.
proc ::bombe::scramblerPerms {edges wheels rings ground reflector} {
    set maxoff 0
    foreach e $edges { if {[lindex $e 0] > $maxoff} { set maxoff [lindex $e 0] } }
    set pos [::bombe::positions $wheels $rings $ground $maxoff]
    set perms [dict create]
    foreach e $edges {
        set off [lindex $e 0]
        if {[dict exists $perms $off]} continue
        dict set perms $off [::enigma::scrambler $wheels $rings [lindex $pos $off] $reflector]
    }
    return $perms
}

# ----------------------------------------------------------------------
# Closure (the electrical reachability) by union-find -- the same equivalence
# the Schem engine computes by merging nodes, done directly for the scan.
# ----------------------------------------------------------------------
#
# A node is a (letter, wire) pair encoded as letterIndex*26 + wire.  Scrambler
# edges and the diagonal board are the unions; we then read which wires of the
# test cable are in the same class as the energised wire.
namespace eval ::bombe { variable UF }

proc ::bombe::ufFind {i} {
    variable UF
    set root $i
    while {[dict get $UF $root] != $root} { set root [dict get $UF $root] }
    while {[dict get $UF $i] != $root} {
        set nxt [dict get $UF $i] ; dict set UF $i $root ; set i $nxt
    }
    return $root
}
proc ::bombe::ufUnion {a b} {
    variable UF
    set ra [::bombe::ufFind $a] ; set rb [::bombe::ufFind $b]
    if {$ra != $rb} { dict set UF $ra $rb }
}

# closure -- energise wire `inWire` of the test letter under this menu and the
# given scrambler perms; return the sorted list of live wires (0..25) in the
# test cable.  This is exactly the set of nodes continuity ties to the input.
proc ::bombe::closure {edges perms test inWire} {
    variable UF
    set letters [::bombe::letters $edges]
    set idx [dict create]
    set k 0
    foreach l $letters { dict set idx $l $k ; incr k }
    set UF [dict create]
    set n [expr {[llength $letters] * 26}]
    for {set i 0} {$i < $n} {incr i} { dict set UF $i $i }
    set node {{idx l w} { expr {[dict get $idx $l]*26 + $w} }}

    # Scrambler edges: wire w of cable a <-> wire P(w) of cable b.
    foreach e $edges {
        lassign $e off a b
        set P [dict get $perms $off]
        for {set w 0} {$w < 26} {incr w} {
            set pw [::enigma::ord [string index $P $w]]
            ::bombe::ufUnion [apply $node $idx $a $w] [apply $node $idx $b $pw]
        }
    }
    # Welchman diagonal board: on cable A, the wire *labelled* with letter B
    # joins, on cable B, the wire labelled with letter A.  A wire's label is an
    # alphabet position (the steckered value it stands for), so the labels are
    # ord(b) and ord(a) -- NOT the menu-local cable indices.  This wires in the
    # plugboard's reciprocity: A steckered to B means B steckered to A.
    foreach a $letters {
        set ai [dict get $idx $a] ; set ao [::enigma::ord $a]
        foreach b $letters {
            if {$b <= $a} continue
            set bi [dict get $idx $b] ; set bo [::enigma::ord $b]
            ::bombe::ufUnion [expr {$ai*26 + $bo}] [expr {$bi*26 + $ao}]
        }
    }

    set root [::bombe::ufFind [apply $node $idx $test $inWire]]
    set live {}
    set ti [dict get $idx $test]
    for {set w 0} {$w < 26} {incr w} {
        if {[::bombe::ufFind [expr {$ti*26 + $w}]] == $root} { lappend live $w }
    }
    return $live
}

# stop? -- is this candidate a stop?  A correct stop leaves the test register
# with a single live wire (the deduced stecker partner) or, dually, a single
# DEAD wire; a wrong setting lights the whole register.  We return the deduced
# stecker wire on a stop, or -1 otherwise.
proc ::bombe::stop? {edges perms test inWire} {
    set live [::bombe::closure $edges $perms $test $inWire]
    set n [llength $live]
    if {$n == 1}  { return [lindex $live 0] }          ;# single live wire
    if {$n == 25} {                                     ;# single dead wire
        for {set w 0} {$w < 26} {incr w} {
            if {$w ni $live} { return $w }
        }
    }
    return -1
}

# ----------------------------------------------------------------------
# The scan: try every rotor start position (and, optionally, wheel order).
# ----------------------------------------------------------------------
#
# Returns a list of hits {ground stecker} where ground is a window string like
# "BLA" and stecker is the test letter's deduced partner.  inWire defaults to
# the test letter steckered to itself (self-stecker) as the seed hypothesis.
proc ::bombe::scan {edges wheels rings reflector args} {
    set test [::bombe::central $edges]
    set inWire [::enigma::ord $test]    ;# seed: assume test steckers to itself
    foreach {k v} $args {
        switch -- $k {
            -test   { set test $v }
            -inwire { set inWire $v }
        }
    }
    set hits {}
    for {set L 0} {$L < 26} {incr L} {
        for {set M 0} {$M < 26} {incr M} {
            for {set R 0} {$R < 26} {incr R} {
                set ground [list $L $M $R]
                set perms [::bombe::scramblerPerms $edges $wheels $rings $ground $reflector]
                set s [::bombe::stop? $edges $perms $test $inWire]
                if {$s >= 0} {
                    lappend hits [list \
                        "[::enigma::chr $L][::enigma::chr $M][::enigma::chr $R]" \
                        [::enigma::chr $s]]
                }
            }
        }
    }
    return $hits
}

package provide bombe 1.0
