# schem.tcl --
#
# Public entry point for the Schem electrical interpreter.
#
#   source schem.tcl
#   set s [schem::new mycircuit]
#   $s add battery B1 -emf 9
#   $s add ground GND
#   ...
#   $s solve
#
# A Schem program *is* a schematic.  This file just wires the engine and
# the transient analyser together and exposes a small convenience API.

namespace eval ::schem {}

set _dir [file dirname [info script]]
source [file join $_dir engine.tcl]
source [file join $_dir transient.tcl]
source [file join $_dir hierarchy.tcl]
source [file join $_dir bus.tcl]
source [file join $_dir netlist.tcl]
source [file join $_dir compile.tcl]
source [file join $_dir backend.tcl]
source [file join $_dir format.tcl]
source [file join $_dir render.tcl]
source [file join $_dir svg.tcl]
source [file join $_dir validate.tcl]
source [file join $_dir editor.tcl]
unset _dir

# schem::new -- create a fresh schematic (board).
proc ::schem::new {{name schematic}} {
    return [::schem::Schematic new $name]
}

# schem::version -- report the engine version.
proc ::schem::version {} {
    variable VERSION
    return $VERSION
}

package provide schem $::schem::VERSION
