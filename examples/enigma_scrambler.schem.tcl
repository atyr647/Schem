# enigma_scrambler.schem.tcl --
#
# An Enigma scrambler as a Schem board, built from bundled conductors.  At a
# fixed rotor position the scrambler is a 26-lane involution: press a key on
# one lane, a lamp lights on lane S(key).  This wires a battery key through the
# scrambler into a 26-lamp alphabet board -- the machine's output panel.
#
#   bin/schem examples/enigma_scrambler.schem.tcl     # press 'A', read the lamp
#   bin/schem save examples/enigma_scrambler.schem.tcl /tmp/scr.schem
#   bin/schem open /tmp/scr.schem                      # draw the board
#
# The wheel order / rings / position below pick which lanes get patched; the
# board that results is pure Schem (components + wires), and matches the
# reference Enigma's scrambler(A) at this setting.
set here [file dirname [file normalize [info script]]]
source [file join $here .. lib crypto enigma.tcl]
source [file join $here .. lib crypto enigma_schem.tcl]

set wheels {I II III} ; set rings AAA ; set pos {0 0 0} ; set refl B

# The key battery and a ground return.
$s add ground GND
$s add battery KEY -emf 12
$s wire KEY.neg GND.t

# Embed a scrambler and an alphabet lampboard, then patch lane-for-lane.
set scr [::enigma::scramblerCircuit $wheels $rings $pos $refl]
set lb  [::enigma::lampboardCircuit]
set sp [$s instantiate $scr SC]
set lp [$s instantiate $lb  LB]
for {set i 0} {$i < 26} {incr i} {
    $s wire [dict get $sp OUT$i] [dict get $lp IN$i]
}

# Press key 'A' -> drive scrambler input lane 0.
$s wire KEY.pos [dict get $sp IN0]

$s solve
