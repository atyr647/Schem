# lib/enigma.tcl --
#
# A historically faithful Wehrmacht Enigma I, in pure Tcl.  This is NOT part
# of the Schem language or any circuit -- it is the *bench oracle*: the known-
# good reference we use to (a) generate a crib + ciphertext to attack and
# (b) confirm that the key the bombe recovers actually decrypts the message.
# The bombe itself is a Schem schematic (see lib/bombe.tcl); this file is the
# electrician's calibrated meter sitting next to it.
#
# Everything here is the real machine: the five Wehrmacht rotor windings,
# their turnover notches, reflectors B and C, the ring setting (Ringstellung),
# the plugboard (Steckerbrett) and -- crucially -- the double-stepping
# anomaly of the middle rotor.  Verified against the canonical test vector
# AAAAA -> BDZGO (UKW-B, wheels I II III, rings AAA, ground AAA, no steckers).

namespace eval ::enigma {
    # The entry wheel (ETW) of the Wehrmacht Enigma is the identity.
    variable ETW ABCDEFGHIJKLMNOPQRSTUVWXYZ

    # Rotor windings (forward, A-mapping) and the notch: the window letter at
    # which the rotor, on stepping, carries the rotor to its left with it.
    variable ROTOR
    array set ROTOR {
        I   {wiring EKMFLGDQVZNTOWYHXUSPAIBRCJ notch Q}
        II  {wiring AJDKSIRUXBLHWTMCQGZNPYFVOE notch E}
        III {wiring BDFHJLCPRTXVZNYEIWGAKMUSQO notch V}
        IV  {wiring ESOVPZJAYQUIRHXLNFTGKDCMWB notch J}
        V   {wiring VZBRGITYUPSDNHLXAWMBQOFECK notch Z}
    }

    # Reflectors (UKW): fixed reciprocal cross-wirings.
    variable REFLECTOR
    array set REFLECTOR {
        B YRUHQSLDPXNGOKMIEBFZCWVJAT
        C FVPJIAOYEDRZXWGCTKUQSBNMHL
    }
}

# ord/chr -- letter <-> 0..25.
proc ::enigma::ord {ch} { scan $ch %c c ; return [expr {$c - 65}] }
proc ::enigma::chr {n}  { format %c [expr {($n % 26) + 65}] }

# inverse -- the inverse of a 26-letter permutation given as a string.
proc ::enigma::inverse {perm} {
    set inv [lrepeat 26 0]
    for {set i 0} {$i < 26} {incr i} {
        lset inv [::enigma::ord [string index $perm $i]] $i
    }
    return $inv
}

# A machine is a dict: wheels (left..right list of rotor names), rings (list of
# 0..25, left..right), pos (list of 0..25, left..right), reflector (B/C), and
# plug (a 26-element involution list, identity by default).
proc ::enigma::new {args} {
    set m [dict create wheels {I II III} rings {0 0 0} pos {0 0 0} \
        reflector B plug {}]
    foreach {k v} $args { dict set m [string trimleft $k -] $v }
    # Normalise ring/pos given as letter strings ("AAA") or numbers.
    foreach key {rings pos} {
        set val [dict get $m $key]
        if {[llength $val] == 1 && [string length $val] == 3} {
            set lst {}
            foreach ch [split $val ""] { lappend lst [::enigma::ord $ch] }
            dict set m $key $lst
        }
    }
    if {[dict get $m plug] eq ""} { dict set m plug [::enigma::plugboard ""] }
    return $m
}

# triple -- normalise a position/ring triple given as a 3-letter string
# ("AAA"), a 3-number list ({0 0 0}), or already-split, into {n n n}.
proc ::enigma::triple {v} {
    if {[llength $v] == 3} { return $v }
    if {[string length $v] == 3} {
        set lst {}
        foreach ch [split $v ""] { lappend lst [::enigma::ord $ch] }
        return $lst
    }
    return -code error "expected a 3-letter string or 3 numbers, got \"$v\""
}

# plugboard -- build the 26-element involution from a spec like "AB CD EF".
# Unpaired letters map to themselves.  This is a reciprocal swap, exactly the
# Steckerbrett: plugging A-B means A<->B.
proc ::enigma::plugboard {spec} {
    set p {}
    for {set i 0} {$i < 26} {incr i} { lappend p $i }
    foreach pair $spec {
        if {[string length $pair] != 2} continue
        set a [::enigma::ord [string index $pair 0]]
        set b [::enigma::ord [string index $pair 1]]
        lset p $a $b ; lset p $b $a
    }
    return $p
}

# Step -- advance the rotors one keypress *before* encipher, including the
# double-stepping anomaly: the middle rotor steps both when the right rotor is
# at its notch and (carrying the left with it) when the middle itself is at its
# notch.  pos is {left middle right}.
proc ::enigma::Step {mVar} {
    upvar 1 $mVar m
    lassign [dict get $m pos] L M R
    lassign [dict get $m wheels] wL wM wR
    variable ROTOR
    set nL [::enigma::ord [dict get $ROTOR($wL) notch]]
    set nM [::enigma::ord [dict get $ROTOR($wM) notch]]
    set nR [::enigma::ord [dict get $ROTOR($wR) notch]]
    set midAtNotch   [expr {$M == $nM}]
    set rightAtNotch [expr {$R == $nR}]
    if {$midAtNotch}   { set M [expr {($M+1)%26}] ; set L [expr {($L+1)%26}] } \
    elseif {$rightAtNotch} { set M [expr {($M+1)%26}] }
    set R [expr {($R+1)%26}]
    dict set m pos [list $L $M $R]
}

# Pass -- send signal s (0..25) through one rotor.  dir is fwd or rev.  The ring
# setting r and position p shift the contact alignment: the wire seen at the
# rotor's contact is (s + p - r), and the rotor's output is shifted back.
proc ::enigma::Pass {wiringFwd wiringInv p r s dir} {
    set x [expr {($s + $p - $r + 26) % 26}]
    if {$dir eq "fwd"} {
        set y [::enigma::ord [string index $wiringFwd $x]]
    } else {
        set y [lindex $wiringInv $x]
    }
    return [expr {($y - $p + $r + 26) % 26}]
}

# encipherChar -- the full path of one character through the (stepped) machine:
# plugboard, right->middle->left rotor, reflector, left->middle->right, plugboard.
proc ::enigma::encipherChar {mVar ch} {
    upvar 1 $mVar m
    ::enigma::Step m
    variable ROTOR ; variable REFLECTOR
    lassign [dict get $m wheels] wL wM wR
    lassign [dict get $m rings]  rL rM rR
    lassign [dict get $m pos]    pL pM pR
    set fwdL [dict get $ROTOR($wL) wiring] ; set invL [::enigma::inverse $fwdL]
    set fwdM [dict get $ROTOR($wM) wiring] ; set invM [::enigma::inverse $fwdM]
    set fwdR [dict get $ROTOR($wR) wiring] ; set invR [::enigma::inverse $fwdR]
    set plug [dict get $m plug]
    set refl $REFLECTOR([dict get $m reflector])

    set s [::enigma::ord $ch]
    set s [lindex $plug $s]
    set s [::enigma::Pass $fwdR $invR $pR $rR $s fwd]
    set s [::enigma::Pass $fwdM $invM $pM $rM $s fwd]
    set s [::enigma::Pass $fwdL $invL $pL $rL $s fwd]
    set s [::enigma::ord [string index $refl $s]]
    set s [::enigma::Pass $fwdL $invL $pL $rL $s rev]
    set s [::enigma::Pass $fwdM $invM $pM $rM $s rev]
    set s [::enigma::Pass $fwdR $invR $pR $rR $s rev]
    set s [lindex $plug $s]
    return [::enigma::chr $s]
}

# encipher -- run a whole message.  Enigma is reciprocal, so the same call
# deciphers (feed ciphertext, same start key, get plaintext).  Non-letters are
# dropped (the operator transmitted only A-Z).
proc ::enigma::encipher {m text} {
    set out ""
    foreach ch [split [string toupper $text] ""] {
        if {![string match {[A-Z]} $ch]} continue
        append out [::enigma::encipherChar m $ch]
    }
    return $out
}

# scrambler -- the bombe's view of the machine: the 26-letter permutation a
# keypress would realise with the plugboard removed, at a given rotor position.
# Because the reflector makes this an involution, it is its own inverse -- which
# is what lets a scrambler be wired as plain bidirectional cable in Schem.
#   wheels/rings as in `new`; pos is the {L M R} position to evaluate AT (no
#   stepping is applied -- the caller chooses the absolute position).
proc ::enigma::scrambler {wheels rings pos reflector} {
    variable ROTOR ; variable REFLECTOR
    lassign $wheels wL wM wR
    lassign [::enigma::triple $rings] rL rM rR
    lassign [::enigma::triple $pos]   pL pM pR
    set fwdL [dict get $ROTOR($wL) wiring] ; set invL [::enigma::inverse $fwdL]
    set fwdM [dict get $ROTOR($wM) wiring] ; set invM [::enigma::inverse $fwdM]
    set fwdR [dict get $ROTOR($wR) wiring] ; set invR [::enigma::inverse $fwdR]
    set refl $REFLECTOR($reflector)
    set out ""
    for {set s 0} {$s < 26} {incr s} {
        set x [::enigma::Pass $fwdR $invR $pR $rR $s fwd]
        set x [::enigma::Pass $fwdM $invM $pM $rM $x fwd]
        set x [::enigma::Pass $fwdL $invL $pL $rL $x fwd]
        set x [::enigma::ord [string index $refl $x]]
        set x [::enigma::Pass $fwdL $invL $pL $rL $x rev]
        set x [::enigma::Pass $fwdM $invM $pM $rM $x rev]
        set x [::enigma::Pass $fwdR $invR $pR $rR $x rev]
        append out [::enigma::chr $x]
    }
    return $out
}

package provide enigma 1.0
