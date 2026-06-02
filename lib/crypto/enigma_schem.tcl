# lib/enigma_schem.tcl --
#
# The Enigma, built as a Schem circuit from bundled conductors -- not a Tcl
# model of one.  A scrambler at a fixed rotor position is, electrically, a
# 26-lane involution: a keypress on lane i comes back out on lane S(i), and
# because the reflector makes S its own inverse, the whole thing is a passive
# patch of copper between an INPUT bus and an OUTPUT bus.  That is exactly what
# the bombe needs, and it is a faithful picture of the machine's wiring at one
# instant.
#
# We use the bus/bank/connect drafting layer so the board reads like a print:
#   bus IN 26 ; bus OUT 26
#   repeat i 0 25 { connect IN[i] -> OUT[S(i)] }
#
# The permutation S itself comes from the rotor windings -- the same historical
# wirings the oracle uses -- evaluated at the chosen wheel order / rings /
# position.  Building the *permutation* is drafting-time arithmetic (it decides
# which lanes to patch); the *board* that results is pure Schem.

package require Tcl 8.6-

# scramblerCircuit -- a reusable Schem circuit for one scrambler at a fixed
# position.  Exposes IN0..IN25 and OUT0..OUT25 (one port per lane) so it embeds
# into a larger board with `instantiate`.  The wiring is the involution S.
proc ::enigma::scramblerCircuit {wheels rings pos reflector {name scrambler}} {
    set S [::enigma::scrambler $wheels $rings $pos $reflector]
    set c [::schem::circuit $name]
    $c bus IN 26
    $c bus OUT 26
    # Patch lane i of IN to lane S(i) of OUT.  Drafting `repeat` stamps the 26
    # real conductors; the electricity is entirely in those wires.
    $c repeat i 0 25 {
        set j [::enigma::ord [string index $S $i]]
        $c connect IN\[$i\] -> OUT\[$j\]
    }
    for {set i 0} {$i < 26} {incr i} {
        $c expose IN$i  [$c lane IN $i]
        $c expose OUT$i [$c lane OUT $i]
    }
    return $c
}

# lampboardCircuit -- the output lampboard: 26 indicator lamps, one per lane of
# a 26-bus, each lit when its lane is energised.  Exposes IN0..IN25 and the GND
# return.  This is the alphabet panel the operator read.
proc ::enigma::lampboardCircuit {{name lampboard}} {
    set c [::schem::circuit $name]
    $c add ground GND
    $c bus IN 26
    $c bank LAMP 26 of lamp -r 2000 -ion 0.0005
    $c connect IN\[*\]      -> LAMP\[*\].a
    $c connect LAMP\[*\].b  -> GND.t
    for {set i 0} {$i < 26} {incr i} { $c expose IN$i [$c lane IN $i] }
    $c expose GND GND.t
    return $c
}

package provide enigma_schem 1.0
