# gui.tcl --
#
# The Schem workbench: a drag-and-drop schematic editor in pure Tcl/Tk.  It is
# a *view* onto a live ::schem::Schematic -- the same object model the engine
# solves and the .schem file stores -- so what you draw is the program.
#
# Layout (a layout an electrical engineer reads at a glance):
#
#   +----------------------------------------------------------------+
#   | menubar:  File  Edit  View  Simulate  Manufacture  Help        |
#   +-------------+--------------------------------------+-----------+
#   | PARTS BIN   |              SCHEMATIC               | INSPECTOR |
#   | (catalog)   |              (canvas)                | (props +  |
#   |  Sources    |   drag parts in, wire pin-to-pin,    |  ratings) |
#   |  Passives   |   probe nodes, run the simulation    |           |
#   |  Active     |                                      |           |
#   |  ...        |                                      |           |
#   +-------------+--------------------------------------+-----------+
#   | status: tool - hint - mouse net/voltage                        |
#   +----------------------------------------------------------------+
#
# This file owns only presentation + interaction; every electrical fact comes
# from the schematic and the engine.  It requires Tk; the headless engine never
# sources it.

package require Tk

# The catalog values carry proper units (Ω, µ): make sure Tk treats our UTF-8
# strings as UTF-8 even when the system encoding is legacy (e.g. iso8859-1).
catch {encoding system utf-8}

namespace eval ::schem::gui {
    # A modern dark design system.  Layered surfaces (deeper = further back),
    # a restrained accent, and semantic state colours an engineer reads at a
    # glance.  Tuned for contrast and calm -- not a wall of grey.
    variable T
    array set T {
        bg       "#16181d"   surface  "#1d2026"   raised   "#23272f"
        hover    "#2b303a"   active   "#323845"   sunken   "#13151a"
        edge     "#2e333d"   edgehi   "#3a414d"
        ink      "#e6e9ef"   dim      "#9aa0ab"   faint    "#5c6370"
        accent   "#5aa0e0"   accent2  "#3d7fc4"   accentdim "#2a4866"
        good     "#5fb87a"   warn     "#e0a458"   bad      "#e06a6a"
        wire     "#aeb4be"   wirelive "#7ec88a"   probe    "#e0c264"
        griddot  "#2a2e36"   gridcross "#353b45"  canvasbg "#191c22"
        symbol   "#cfd4dd"   pin      "#7d8694"   pinhot   "#5aa0e0"
        sel      "#5aa0e0"   selfill  "#1e3450"
    }
    # Type scale (DejaVu Sans is available and clean).
    variable FONT       {"DejaVu Sans" 10}
    variable FONTSM     {"DejaVu Sans" 9}
    variable FONTMONO   {"DejaVu Sans Mono" 9}
    variable FONTH      {"DejaVu Sans" 9 bold}
    variable FONTTITLE  {"DejaVu Sans" 13 bold}
    variable FONTBIG    {"DejaVu Sans" 20 bold}
    variable _wincount 0
    variable _binY 0
    variable _binN 0

    # mix -- blend two #rrggbb colours by fraction f (0=a, 1=b).  Used for
    # hover/press shading so states feel continuous.
    proc mix {a b f} {
        scan $a "#%2x%2x%2x" ar ag ab
        scan $b "#%2x%2x%2x" br bg bb
        return [format "#%02x%02x%02x" \
            [expr {int($ar+($br-$ar)*$f)}] \
            [expr {int($ag+($bg-$ag)*$f)}] \
            [expr {int($ab+($bb-$ab)*$f)}]]
    }
    # roundrect -- a rounded rectangle as a smoothed polygon on a canvas.
    proc roundrect {c x1 y1 x2 y2 r args} {
        set pts [list \
            $x1 [expr {$y1+$r}]  $x1 $y1  [expr {$x1+$r}] $y1 \
            [expr {$x2-$r}] $y1  $x2 $y1  $x2 [expr {$y1+$r}] \
            $x2 [expr {$y2-$r}]  $x2 $y2  [expr {$x2-$r}] $y2 \
            [expr {$x1+$r}] $y2  $x1 $y2  $x1 [expr {$y2-$r}]]
        return [$c create polygon $pts -smooth 1 -splinesteps 12 {*}$args]
    }
}

# ---------------------------------------------------------------------------
#  App -- one editor window over one schematic.
# ---------------------------------------------------------------------------
oo::class create ::schem::gui::App {
    variable S          ;# the schematic (model)
    variable Win        ;# toplevel
    variable Canvas     ;# the schematic canvas
    variable Tbar       ;# the custom toolbar canvas
    variable TbarW      ;# last toolbar width (resize debounce)
    variable TbarBusy   ;# reentrancy guard for DrawToolbar
    variable Parts      ;# parts-bin canvas
    variable CatBtn     ;# parts-bin category filter menubutton
    variable Insp       ;# inspector frame
    variable Status     ;# status bar text var (array-backed)
    variable File       ;# current .schem path ("" if unsaved)
    variable Dirty      ;# unsaved changes?
    variable Std        ;# symbol standard: iec | ansi
    variable Tool       ;# current interaction: select | wire | probe
    variable Placed     ;# name -> {type x y rot pins partid}  (canvas placement)
    variable Wires      ;# list of {from to id}  (terminal a -> terminal b)
    variable Sel        ;# selected component name ("" if none)
    variable Counter    ;# per-type auto-name counter
    variable Grid       ;# snap grid in px (world units)
    variable Zoom       ;# canvas zoom factor (1.0 = 100%)
    variable PendWire   ;# wire-in-progress: starting terminal or ""
    variable Pending    ;# armed placement: {primitive TYPE} | {part ID} | ""
    variable Result     ;# last solve result flag
    variable StatusChip ;# status-bar state chip widget
    variable BinQuery   ;# parts-bin search text
    variable BinCat     ;# parts-bin active category filter ("all" or a name)
    variable Drag       ;# in-progress drag-from-bin: dict or ""

    constructor {{schem {}} {parent {}}} {
        if {$schem eq ""} { set S [::schem::new untitled] } else { set S $schem }
        set File "" ; set Dirty 0 ; set Std ansi ; set Tool select
        set Placed [dict create] ; set Wires {} ; set Sel ""
        set Counter [dict create] ; set Grid 20 ; set PendWire "" ; set Result none
        set Pending "" ; set Zoom 1.0 ; set BinQuery "" ; set BinCat all ; set Drag ""
        my BuildUI [expr {$parent eq "" ? "." : $parent}]
        if {$schem ne ""} {
            # opened with an existing board -- lay it out on the canvas
            my RebuildFromSchematic
        } else {
            my Redraw
        }
        my SetStatus "Ready.  Drag a part from the bin, or click a part then click the canvas."
    }

    method schematic {} { return $S }
    method window {} { return $Win }

    # do -- exported entry point so the app can be driven programmatically (for
    # scripting and headless tests): forwards to an internal method.  e.g.
    #   $app do pick-primitive resistor ; $app do click 240 360
    method do {action args} {
        switch -- $action {
            pick-primitive { my PickPrimitive {*}$args }
            pick-part      { my PickPart {*}$args }
            click          { my OnClick {*}$args }
            tool           { my SetTool {*}$args }
            command        { my Cmd {*}$args }
            select         { set Sel [lindex $args 0] ; my Redraw ; my ShowInspector }
            wire           { my AddWire {*}$args }
            set-param      { my SetParam [lindex $args 0] [lindex $args 1] [lindex $args 2] }
            sync-wires     { my RebuildFromSchematic }
            save-to        { set File [lindex $args 0] ; my CmdSave }
            placed         { return [dict keys $Placed] }
            wires          { return $Wires }
            result         { return $Result }
            zoom           { return $Zoom }
            compile        { my SyncPositions ; return [::schem::emit $S zig] }
            validate-text  { my SyncPositions ; return [$S validateText] }
            netlist-text   { my SyncPositions ; return [$S netlistText] }
            run-transient  { return [$S run -duration [lindex $args 0] -dt [lindex $args 1] -record [lrange $args 2 end]] }
            ac-mag         {
                # ac-mag NODE FREQ -> magnitude (linear) at one frequency
                set sw [$S acsweep [list [lindex $args 1]]]
                return [$S acmag [$S acnode $sw [lindex $args 1] [lindex $args 0]]]
            }
            fit            { my CmdFitAll }
            dblclick       { my OnDoubleClick {*}$args }
            stateof        { return [expr {![catch {$S get [lindex $args 0] state} v] ? $v : ""}] }
            verdict        { return [expr {[dict exists $Placed [lindex $args 0] verdict] ? [dict get $Placed [lindex $args 0] verdict] : "ok"}] }
            redraw         { my Redraw }
            default        { return -code error "unknown do action: $action" }
        }
    }

    # callback -- a command prefix that invokes a method on THIS object, for
    # -command / bind.  Tk runs these at global scope, where unexported
    # (capitalised) methods are not visible -- so we route through `dispatch`,
    # an exported forwarder.  (Tcl 8.7's built-in `callback` handles this; we
    # provide our own so the workbench runs on stock 8.6.)  Trailing
    # %-substitutions from bind are appended by Tk after these args.
    method callback {args} { return [list [self] dispatch {*}$args] }
    method dispatch {m args} { my $m {*}$args }
    export dispatch

    # ----- UI construction -------------------------------------------------
    method BuildUI {root} {
        variable ::schem::gui::T
        # First window owns "."; any further window gets its own toplevel, so
        # several boards can be open at once (and tests can spin up many apps).
        if {$root eq "."} {
            if {[llength [winfo children .]] == 0 && ![winfo exists .menu]} {
                set Win .
            } else {
                set Win [toplevel .schem[incr ::schem::gui::_wincount]]
            }
        } else {
            set Win $root
        }
        wm title $Win "Schem -- electrical workbench"
        $Win configure -bg $T(bg)
        catch {wm geometry $Win 1500x900}

        my BuildMenu
        my BuildToolbar
        # main 3-pane area
        set main [frame $Win.main -bg $T(bg)]
        pack $main -side top -fill both -expand 1
        my BuildPartsBin $main
        my BuildCanvas   $main
        my BuildInspector $main
        my BuildStatusBar
        my ApplyTheme
    }

    # A custom-drawn toolbar: rounded "pill" buttons with little glyph icons,
    # hover and active states, and a segmented tool group on the left.  Far
    # cleaner than stock Tk buttons.

    # toolbar button registry: id -> {x1 x2 kind value icon label}

    # TbarPill -- one rounded toolbar button with an icon and hover/active state.

    # DrawIcon -- a tiny 14px line glyph, centred at (x,y).

    # BuildCatMenu -- fill the category dropdown: All, Basics, then one per
    # real-part category.

    # Placeholder -- show grey hint text in an entry until the user types.

    # SetCat -- choose the active category filter; update the button label and
    # re-filter the list.

    method BuildStatusBar {} {
        variable ::schem::gui::T
        set sb [frame $Win.sb -bg $T(sunken) -height 26]
        pack $sb -side bottom -fill x
        pack propagate $sb 0
        # a small state chip on the left
        label $sb.chip -textvariable [my varname Status](chip) -bg $T(sunken) \
            -fg $T(bg) -font {"DejaVu Sans" 8 bold} -padx 8
        pack $sb.chip -side left -fill y -pady 4 -padx {8 0}
        label $sb.l -textvariable [my varname Status](text) -bg $T(sunken) -fg $T(dim) \
            -anchor w -padx 10 -font $::schem::gui::FONTSM
        pack $sb.l -side left -fill x -expand 1
        label $sb.r -textvariable [my varname Status](right) -bg $T(sunken) -fg $T(accent) \
            -anchor e -padx 12 -font $::schem::gui::FONTMONO
        pack $sb.r -side right
        set StatusChip $sb.chip
    }

    method ApplyTheme {} {
        variable ::schem::gui::T
        # ttk-free; just ensure option defaults for any future widgets
        option add *background $T(surface)
        option add *foreground $T(ink)
    }

    method SetStatus {msg {right ""}} {
        variable ::schem::gui::T
        set Status(text) $msg ; set Status(right) $right
        # colour a small state chip from the right-hand keyword
        set chip "" ; set col $T(dim)
        switch -glob -- $right {
            OK    { set chip " OK " ; set col $T(good) }
            WARN  { set chip "WARN" ; set col $T(warn) }
            FAIL  { set chip "FAIL" ; set col $T(bad) }
            *=*V  { set chip "  V " ; set col $T(probe) }
        }
        set Status(chip) $chip
        if {[info exists StatusChip] && [winfo exists $StatusChip]} {
            $StatusChip configure -bg [expr {$chip eq "" ? $T(sunken) : $col}]
        }
    }

    # ----- parts bin -------------------------------------------------------
    # The catalog an engineer reaches into: primitive building blocks at the
    # top (the raw electrical elements), then the REAL parts grouped by the job
    # they do (rectifier, smoothing, transistor, ...).  Click a part, then click
    # the canvas to place it -- or drag it straight onto the board.
    # PopulateParts -- draw the bin as a column of rows, each showing the part's
    # actual schematic symbol beside its name, so you recognise it on sight.
    # PopulateParts -- draw the bin, honouring the search query and the active
    # category chip so the list stays short.  A category shows only when it has
    # matching parts.

    # BinRow -- one selectable row: a small symbol preview + label (+ part id).
    #   type  : schem primitive (for the symbol)
    #   label : display name
    #   desc  : datasheet one-liner (real parts; "" for primitives)
    #   partid: catalog id ("" for a primitive)

    # ShortDesc -- trim a datasheet line to the headline (before the "--").

    # PickPrimitive / PickPart -- arm placement of the chosen part; the next
    # canvas click drops it.

    # ----- drag-and-drop from the parts bin --------------------------------
    # Press on a bin row arms placement and records the start; dragging shows a
    # floating ghost of the symbol that follows the cursor; releasing over the
    # canvas drops the part there.  A click without a drag still arms placement
    # (so click-then-click works too).
    # a small floating toplevel that mirrors the dragged symbol under the cursor

    method SetTool {t} { set Tool $t ; set PendWire "" ; my SetStatus "Tool: $t" ; my DrawToolbar ; my Redraw }

    # ----- zoom ------------------------------------------------------------
    # FitToContent -- choose a zoom so the whole board fits the viewport.
    # Zoom toward the cursor on wheel scroll.

    # ----- the canvas: grid, symbols, wires, probes ------------------------

    # A floating control cluster in the bottom-right of the canvas: zoom out,
    # the current percentage (click to reset to 100%), and zoom in.  Drawn as
    # canvas items pinned to the viewport so it stays put while you pan/zoom.

    # DrawWelcome -- the empty-board hint: a quiet pointer to the workflow, so a
    # first-time user (or an EE sizing the tool up) knows exactly what to do.

    # A dot grid -- a dot at each snap point, brighter on the major (5-grid)
    # intersections.  Cleaner and less busy than ruled lines, the way modern
    # design/EDA canvases look.

    # DrawComponent -- render a placed part's schematic symbol + pin dots, and
    # record the absolute pin coordinates for wiring.

    # ----- interaction -----------------------------------------------------

    # SnapW -- screen pixel -> snapped WORLD coordinate.

    # OnDoubleClick -- toggle an operable part (switch, button, breaker, fuse
    # reset) so you can flip contacts and re-solve, like operating the board.

    # ComponentAt -- nearest component to a WORLD-coordinate point.

    # wiring: first click selects a start pin, second click a finish pin

    # AddWire -- wire two terminals by name (model + canvas), for scripting and
    # the load path.  Skips if either endpoint isn't a placed component.

    # ----- inspector -------------------------------------------------------

    # ShowMeasured -- the selected part's solved operating point.

    # InspSection -- a small section header with a hairline rule.

    # ----- commands --------------------------------------------------------

    # TextDialog -- a reusable scrollable, monospace, read-only text window for
    # the netlist, the validation report, the compiled output, etc.  Optionally
    # offers a "Save..." button writing the body to a file.

    # CmdValidate -- run the anti-spaghetti + electrical design-rule checks and
    # show the report (the DRC an engineer runs before committing a board).

    # CmdNetlist -- show the derived netlist (nodes + elements), the connectivity
    # the simulator and exporters consume.

    # CmdCompile -- compile the board down to a standalone Zig program that
    # solves it, the same backend the CLI's `emit zig` uses.  This is the
    # "compile down" path: the schematic becomes native code you can build and
    # run with `zig run`.

    # CmdTransient -- time-domain analysis (for AC sources, RC/RL timing,
    # rectifier ripple, oscillators).  Asks for a duration + step, runs, and
    # plots the recorded node waveforms.

    # ----- transient analysis dialog ---------------------------------------
    # A time-domain run with a small controls strip (duration, step, which node
    # to plot) and a live oscilloscope-style plot.  This is what brings the AC
    # sources, RC/RL timing and rectifier ripple to life in the GUI.

    # PlotWave -- a simple oscilloscope trace of v(t) with autoscaled axes.

    # ----- AC frequency sweep (Bode) ---------------------------------------

    # PlotBode -- magnitude (dB, top) + phase (deg, bottom) vs log frequency.

    # Persist current canvas positions onto the model before saving.
    # Rebuild canvas placement from a loaded schematic (positions + wires).

}

