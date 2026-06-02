# gui/load.tcl -- load the Tk workbench.
#
# Sources the symbol renderers (view/) and the App class split across
# gui/*.tcl.  Requires Tk and a display; the headless engine never sources
# this.  bin/schem-gui and the GUI tests source THIS one file.

set _gdir [file dirname [info script]]
# symbol rendering (in view/, Tk-free at parse time but used by the GUI)
source [file join $_gdir .. view symbols.tcl]
source [file join $_gdir .. view ksym.tcl]
# the App class: base first, then the topic extensions
foreach _f {app.tcl menu.tcl partsbin.tcl canvas.tcl inspector.tcl analysis.tcl commands.tcl} {
    source [file join $_gdir $_f]
}
unset _gdir _f
