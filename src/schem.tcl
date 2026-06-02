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
# A Schem program *is* a schematic.  This file wires the engine together from
# its compartmentalised source tree and exposes a small convenience API.
#
# Source layout (each directory is one concern):
#   core/    the engine        -- object model, solver, MNA, transient, AC,
#                                  hierarchy, bus drafting
#   io/      persistence/IR    -- .schem format, derived netlist, Circuit IR,
#                                  validation
#   backend/ IR backends       -- dispatch + zig / dcref / digital emitters
#   view/    rendering          -- ASCII viewer, SVG, zoom, symbols (no Tk)
#   export/  manufacturing      -- PCB (KiCad netlist + BOM)
#   tui/     terminal editor
#   gui/     the Tk workbench   (loaded only by bin/schem-gui, needs Tk)

namespace eval ::schem {}

set _dir [file dirname [info script]]

# Each entry is sourced in order; engine.tcl self-loads solver/simulate/ac.
foreach _f {
    core/engine.tcl
    core/transient.tcl
    core/hierarchy.tcl
    core/bus.tcl
    io/netlist.tcl
    io/compile.tcl
    backend/backend.tcl
    backend/dcref.tcl
    backend/zig.tcl
    backend/digital.tcl
    io/format.tcl
    view/render.tcl
    view/zoom.tcl
    view/svg.tcl
    export/pcb.tcl
    io/validate.tcl
    tui/editor.tcl
} {
    source [file join $_dir $_f]
}
unset _dir _f

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
