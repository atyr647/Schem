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
            fit            { my CmdFitAll }
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

    method Submenu {parent name} {
        variable ::schem::gui::T
        return [menu $parent.$name -tearoff 0 -bg $T(raised) -fg $T(ink) \
            -activebackground $T(accent2) -activeforeground white \
            -bd 0 -relief flat -font $::schem::gui::FONT]
    }

    method BuildMenu {} {
        variable ::schem::gui::T
        set m [menu $Win.menu -tearoff 0 -bg $T(surface) -fg $T(ink) \
            -activebackground $T(accent2) -activeforeground white -bd 0]
        $Win configure -menu $m
        set fm [my Submenu $m file]
        $m add cascade -label File -menu $fm
        $fm add command -label "New"        -accelerator Ctrl+N -command [my callback Cmd new]
        $fm add command -label "Open…"      -accelerator Ctrl+O -command [my callback Cmd open]
        $fm add command -label "Save"       -accelerator Ctrl+S -command [my callback Cmd save]
        $fm add command -label "Save As…"                       -command [my callback Cmd saveas]
        $fm add separator
        $fm add command -label "Export image (SVG)…"            -command [my callback Cmd export_svg]
        $fm add command -label "Export PCB (KiCad + BOM)…"      -command [my callback Cmd export_pcb]
        $fm add command -label "Compile to Zig…"                -command [my callback Cmd compile]
        $fm add command -label "Show netlist…"                  -command [my callback Cmd netlist]
        $fm add separator
        $fm add command -label "Quit"       -accelerator Ctrl+Q -command [my callback Cmd quit]
        set em [my Submenu $m edit]
        $m add cascade -label Edit -menu $em
        $em add command -label "Delete selected" -accelerator Del -command [my callback Cmd delete]
        $em add command -label "Rotate selected" -accelerator R   -command [my callback Cmd rotate]
        $em add command -label "Clear board"                      -command [my callback Cmd clear]
        set vm [my Submenu $m view]
        $m add cascade -label View -menu $vm
        $vm add command -label "Zoom in"  -accelerator + -command [my callback Cmd zoomin]
        $vm add command -label "Zoom out" -accelerator - -command [my callback Cmd zoomout]
        $vm add command -label "Zoom 100%" -accelerator 0 -command [my callback Cmd zoomreset]
        $vm add command -label "Fit board to window" -accelerator F -command [my callback Cmd fitall]
        $vm add separator
        $vm add command -label "Symbols: ANSI ⇄ IEC" -accelerator T -command [my callback Cmd togglestd]
        set sm [my Submenu $m sim]
        $m add cascade -label Simulate -menu $sm
        $sm add command -label "Solve (DC operating point)" -accelerator F5 -command [my callback Cmd solve]
        $sm add command -label "Transient analysis…"        -command [my callback Cmd transient]
        $sm add separator
        $sm add command -label "Design-rule check…"         -command [my callback Cmd validate]
        $sm add command -label "Clear results"              -command [my callback Cmd clearresults]
        set mm [my Submenu $m man]
        $m add cascade -label Manufacture -menu $mm
        $mm add command -label "Design review (check ratings)" -command [my callback Cmd review]
        $mm add separator
        $mm add command -label "Export PCB (KiCad + BOM)…"   -command [my callback Cmd export_pcb]
        $mm add command -label "Compile to Zig…"             -command [my callback Cmd compile]
        set hm [my Submenu $m help]
        $m add cascade -label Help -menu $hm
        $hm add command -label "Keys & tools" -command [my callback Cmd help]
        $hm add command -label "About Schem"  -command [my callback Cmd about]

        # accelerators
        bind $Win <Control-n> [my callback Cmd new]
        bind $Win <Control-o> [my callback Cmd open]
        bind $Win <Control-s> [my callback Cmd save]
        bind $Win <Control-q> [my callback Cmd quit]
        bind $Win <F5>        [my callback Cmd solve]
        bind $Win <Key-Delete> [my callback Cmd delete]
        bind $Win <Key-r>     [my callback Cmd rotate]
        bind $Win <Key-t>     [my callback Cmd togglestd]
        bind $Win <Key-f>     [my callback Cmd fitall]
        bind $Win <Key-plus>  [my callback ZoomIn]
        bind $Win <Key-equal> [my callback ZoomIn]
        bind $Win <Key-minus> [my callback ZoomOut]
        bind $Win <Key-0>     [my callback ZoomReset]
    }

    # A custom-drawn toolbar: rounded "pill" buttons with little glyph icons,
    # hover and active states, and a segmented tool group on the left.  Far
    # cleaner than stock Tk buttons.
    method BuildToolbar {} {
        variable ::schem::gui::T
        set Tbar [canvas $Win.tb -bg $T(raised) -height 52 -highlightthickness 0 -bd 0]
        pack $Tbar -side top -fill x
        set TbarW 0
        # redraw only when the width actually changes (item creation can re-fire
        # <Configure> with the same width; a reentrancy guard makes that a no-op).
        bind $Tbar <Configure> [my callback OnTbarConfigure %w]
        after 40 [my callback DrawToolbar]
    }

    method OnTbarConfigure {w} {
        if {$w == $TbarW} return
        set TbarW $w
        my DrawToolbar
    }

    # toolbar button registry: id -> {x1 x2 kind value icon label}
    method DrawToolbar {} {
        variable ::schem::gui::T
        if {![winfo exists $Tbar]} return
        if {[info exists TbarBusy] && $TbarBusy} return
        set TbarBusy 1
        set TbarW [winfo width $Tbar]
        $Tbar delete all
        set x 12 ; set y 10 ; set h 32
        # segmented tool group
        set tools {select Select cursor  wire Wire wire  probe Probe probe}
        set gx0 $x
        foreach {val label icon} $tools {
            set w [expr {[font measure {"DejaVu Sans" 9} $label] + 46}]
            set on [expr {$Tool eq $val}]
            my TbarPill tool $val $x $y [expr {$x+$w}] [expr {$y+$h}] $label $icon $on
            set x [expr {$x+$w+4}]
        }
        # divider
        incr x 8
        $Tbar create line $x [expr {$y+4}] $x [expr {$y+$h-4}] -fill $T(edge)
        incr x 12
        # action buttons
        foreach {cmd label icon} {solve "Solve" play  review "Design review" check  rotate "Rotate" rot  delete "Delete" trash} {
            set w [expr {[font measure {"DejaVu Sans" 9} $label] + 46}]
            my TbarPill action $cmd $x $y [expr {$x+$w}] [expr {$y+$h}] $label $icon 0
            set x [expr {$x+$w+4}]
        }
        # right side: symbol-standard toggle
        set W [winfo width $Tbar] ; if {$W < 50} { set W 1400 }
        set sw 150
        my TbarPill std toggle [expr {$W-$sw-12}] $y [expr {$W-12}] [expr {$y+$h}] \
            "Symbols: [string toupper $Std]" sym 0
        set TbarBusy 0
    }

    # TbarPill -- one rounded toolbar button with an icon and hover/active state.
    method TbarPill {kind value x1 y1 x2 y2 label icon active} {
        variable ::schem::gui::T
        set tag "tb_${kind}_${value}"
        if {$active} { set fill $T(accent2) ; set fg white ; set ic white } \
        else { set fill $T(surface) ; set fg $T(ink) ; set ic $T(dim) }
        set bgid [::schem::gui::roundrect $Tbar $x1 $y1 $x2 $y2 7 -fill $fill -outline "" -tags $tag]
        set iconx [expr {$x1+16}] ; set icy [expr {($y1+$y2)/2}]
        my DrawIcon $Tbar $icon $iconx $icy $ic $tag
        $Tbar create text [expr {$x1+30}] $icy -text $label -anchor w -fill $fg \
            -font {"DejaVu Sans" 9} -tags $tag
        # interaction
        switch -- $kind {
            tool   { set cmd [my callback SetTool $value] }
            action { set cmd [my callback Cmd $value] }
            std    { set cmd [my callback Cmd togglestd] }
        }
        $Tbar bind $tag <Button-1> $cmd
        if {!$active} {
            $Tbar bind $tag <Enter> [list $Tbar itemconfigure $bgid -fill $T(hover)]
            $Tbar bind $tag <Leave> [list $Tbar itemconfigure $bgid -fill $T(surface)]
        }
    }

    # DrawIcon -- a tiny 14px line glyph, centred at (x,y).
    method DrawIcon {c name x y col tag} {
        set s 6
        switch -- $name {
            cursor {
                $c create line $x [expr {$y-$s}] $x [expr {$y+$s-1}] [expr {$x+4}] [expr {$y+2}] [expr {$x-1}] [expr {$y+2}] \
                    -fill $col -width 1.5 -tags $tag
            }
            wire {
                $c create line [expr {$x-$s}] [expr {$y+$s}] [expr {$x+$s}] [expr {$y-$s}] -fill $col -width 2 -tags $tag
                $c create oval [expr {$x-$s-2}] [expr {$y+$s-2}] [expr {$x-$s+2}] [expr {$y+$s+2}] -fill $col -outline $col -tags $tag
                $c create oval [expr {$x+$s-2}] [expr {$y-$s-2}] [expr {$x+$s+2}] [expr {$y-$s+2}] -fill $col -outline $col -tags $tag
            }
            probe {
                $c create line [expr {$x-$s}] [expr {$y+$s}] [expr {$x+2}] [expr {$y-2}] -fill $col -width 2 -tags $tag
                $c create line [expr {$x+1}] [expr {$y-3}] [expr {$x+$s}] [expr {$y-$s}] -fill $col -width 3 -tags $tag
            }
            play {
                $c create polygon [expr {$x-4}] [expr {$y-$s}] [expr {$x-4}] [expr {$y+$s}] [expr {$x+$s}] $y \
                    -fill $col -outline $col -tags $tag
            }
            check {
                $c create line [expr {$x-$s}] $y [expr {$x-1}] [expr {$y+$s-1}] [expr {$x+$s}] [expr {$y-$s}] \
                    -fill $col -width 2 -tags $tag
            }
            rot {
                $c create arc [expr {$x-$s}] [expr {$y-$s}] [expr {$x+$s}] [expr {$y+$s}] -start 40 -extent 280 \
                    -style arc -outline $col -width 1.5 -tags $tag
                $c create line [expr {$x+$s-1}] [expr {$y-$s+1}] [expr {$x+2}] [expr {$y-$s+1}] -fill $col -width 1.5 -tags $tag
                $c create line [expr {$x+$s-1}] [expr {$y-$s+1}] [expr {$x+$s-1}] [expr {$y-1}] -fill $col -width 1.5 -tags $tag
            }
            trash {
                $c create rectangle [expr {$x-4}] [expr {$y-3}] [expr {$x+4}] [expr {$y+$s}] -outline $col -width 1.5 -tags $tag
                $c create line [expr {$x-$s}] [expr {$y-3}] [expr {$x+$s}] [expr {$y-3}] -fill $col -width 1.5 -tags $tag
                $c create line [expr {$x-2}] [expr {$y-5}] [expr {$x+2}] [expr {$y-5}] -fill $col -width 1.5 -tags $tag
            }
            sym {
                $c create line [expr {$x-$s}] $y [expr {$x-2}] $y -fill $col -width 1.5 -tags $tag
                $c create rectangle [expr {$x-2}] [expr {$y-3}] [expr {$x+2}] [expr {$y+3}] -outline $col -width 1.5 -tags $tag
                $c create line [expr {$x+2}] $y [expr {$x+$s}] $y -fill $col -width 1.5 -tags $tag
            }
        }
    }

    method BuildPartsBin {parent} {
        variable ::schem::gui::T
        set f [frame $parent.bin -bg $T(surface) -width 250]
        pack $f -side left -fill y
        pack propagate $f 0
        # One compact control row: a search field that fills, plus a category
        # filter button on the right.  No separate title -- the search field's
        # placeholder says what it is.
        set top [frame $f.top -bg $T(surface)]
        pack $top -side top -fill x -padx 8 -pady 8
        set sbox [frame $top.box -bg $T(raised) -highlightthickness 1 \
            -highlightbackground $T(edge) -highlightcolor $T(accent)]
        pack $sbox -side left -fill x -expand 1
        label $sbox.ic -text "⌕" -bg $T(raised) -fg $T(dim) -font {"DejaVu Sans" 11}
        pack $sbox.ic -side left -padx {6 0}
        set ent [entry $sbox.e -bg $T(raised) -fg $T(ink) -insertbackground $T(accent) \
            -relief flat -font $::schem::gui::FONTSM -textvariable [my varname BinQuery]]
        pack $ent -side left -fill x -expand 1 -pady 3 -padx {2 4}
        bind $ent <KeyRelease> [my callback PopulateParts]
        my Placeholder $ent "Search parts"
        # category filter -- a compact menubutton showing the active filter
        set CatBtn [menubutton $top.cat -bg $T(raised) -fg $T(ink) \
            -activebackground $T(hover) -activeforeground $T(ink) -relief flat \
            -font $::schem::gui::FONTSM -padx 8 -pady 3 -direction below \
            -indicatoron 0 -text "All ▾"]
        pack $CatBtn -side left -padx {6 0} -fill y
        set cm [menu $CatBtn.m -tearoff 0 -bg $T(raised) -fg $T(ink) \
            -activebackground $T(accent2) -activeforeground white -bd 0]
        $CatBtn configure -menu $cm
        my BuildCatMenu $cm
        # scrollable list of symbol rows, with a proper visible scrollbar
        set tree [frame $f.tree -bg $T(surface)]
        pack $tree -side top -fill both -expand 1
        set Parts [canvas $tree.c -bg $T(surface) -highlightthickness 0 -bd 0]
        # a clearly visible scrollbar: a lighter thumb on a darker trough
        scrollbar $tree.sb -orient vertical -command [list $Parts yview] \
            -bg $T(edgehi) -activebackground $T(accent) -troughcolor $T(sunken) \
            -bd 0 -highlightthickness 0 -width 13 -relief flat -elementborderwidth 1
        $Parts configure -yscrollcommand [list $tree.sb set]
        pack $tree.sb -side right -fill y
        pack $Parts -side left -fill both -expand 1
        bind $Parts <Button-4> [list $Parts yview scroll -2 units]
        bind $Parts <Button-5> [list $Parts yview scroll 2 units]
        bind $Parts <MouseWheel> [list $Parts yview scroll {%D -120 /} units]
        my PopulateParts
    }

    # BuildCatMenu -- fill the category dropdown: All, Basics, then one per
    # real-part category.
    method BuildCatMenu {m} {
        $m delete 0 end
        $m add command -label "All parts" -command [my callback SetCat all]
        $m add command -label "Basic elements" -command [my callback SetCat basics]
        $m add separator
        foreach c [::schem::parts::categories] {
            $m add command -label [my TitleCase $c] -command [my callback SetCat $c]
        }
    }

    # Placeholder -- show grey hint text in an entry until the user types.
    method Placeholder {e text} {
        variable ::schem::gui::T
        $e insert 0 $text
        $e configure -fg $T(faint)
        bind $e <FocusIn> [list apply {{e text dim ink} {
            if {[$e get] eq $text} { $e delete 0 end ; $e configure -fg $ink }
        }} $e $text $T(faint) $T(ink)]
        bind $e <FocusOut> [list apply {{e text dim} {
            if {[$e get] eq ""} { $e insert 0 $text ; $e configure -fg $dim }
        }} $e $text $T(faint)]
    }

    # SetCat -- choose the active category filter; update the button label and
    # re-filter the list.
    method SetCat {key} {
        set BinCat $key
        if {[info exists CatBtn] && [winfo exists $CatBtn]} {
            switch -- $key {
                all     { set label "All" }
                basics  { set label "Basics" }
                default { set label [my TitleCase $key] }
            }
            $CatBtn configure -text "$label ▾"
        }
        my PopulateParts
    }

    method BuildCanvas {parent} {
        variable ::schem::gui::T
        set f [frame $parent.cv -bg $T(canvasbg)]
        pack $f -side left -fill both -expand 1
        set Canvas [canvas $f.c -bg $T(canvasbg) -highlightthickness 0]
        set hsb [scrollbar $f.h -orient horizontal -command [list $Canvas xview] \
            -bd 0 -highlightthickness 0 -bg $T(surface) -troughcolor $T(canvasbg) \
            -activebackground $T(edgehi) -elementborderwidth 0 -width 11]
        set vsb [scrollbar $f.v -orient vertical -command [list $Canvas yview] \
            -bd 0 -highlightthickness 0 -bg $T(surface) -troughcolor $T(canvasbg) \
            -activebackground $T(edgehi) -elementborderwidth 0 -width 11]
        $Canvas configure -xscrollcommand [list $hsb set] -yscrollcommand [list $vsb set] \
            -scrollregion {0 0 2000 1400}
        grid $Canvas -row 0 -column 0 -sticky nsew
        grid $vsb -row 0 -column 1 -sticky ns
        grid $hsb -row 1 -column 0 -sticky ew
        grid rowconfigure $f 0 -weight 1
        grid columnconfigure $f 0 -weight 1
        # interaction bindings
        bind $Canvas <Button-1>        [my callback OnClick %x %y]
        bind $Canvas <B1-Motion>       [my callback OnDrag %x %y]
        bind $Canvas <ButtonRelease-1> [my callback OnRelease %x %y]
        bind $Canvas <Motion>          [my callback OnHover %x %y]
        bind $Canvas <Button-3>        [my callback OnRightClick %x %y]
        # mouse-wheel zoom (Ctrl+wheel) toward the cursor
        bind $Canvas <Control-Button-4> [my callback WheelZoom 1 %x %y]
        bind $Canvas <Control-Button-5> [my callback WheelZoom -1 %x %y]
        bind $Canvas <Control-MouseWheel> [my callback WheelZoom %D %x %y]
        # plain wheel scrolls vertically; Shift+wheel horizontally
        bind $Canvas <Button-4> [list $Canvas yview scroll -1 units]
        bind $Canvas <Button-5> [list $Canvas yview scroll 1 units]
        bind $Canvas <Shift-Button-4> [list $Canvas xview scroll -1 units]
        bind $Canvas <Shift-Button-5> [list $Canvas xview scroll 1 units]
        # pan with the middle button (or space-drag) -- grab the empty canvas
        bind $Canvas <ButtonPress-2>   [list $Canvas scan mark %x %y]
        bind $Canvas <B2-Motion>       [list $Canvas scan dragto %x %y 1]
    }

    method BuildInspector {parent} {
        variable ::schem::gui::T
        set f [frame $parent.insp -bg $T(surface) -width 296]
        pack $f -side right -fill y
        pack propagate $f 0
        # a thin accent edge on the left of the panel
        frame $f.edge -bg $T(edge) -width 1
        pack $f.edge -side left -fill y
        set inner [frame $f.in -bg $T(surface)]
        pack $inner -side left -fill both -expand 1
        label $inner.h -text "Inspector" -bg $T(surface) -fg $T(ink) -anchor w \
            -font $::schem::gui::FONTTITLE -padx 16
        pack $inner.h -side top -fill x -pady {12 8}
        set Insp [frame $inner.body -bg $T(surface)]
        pack $Insp -side top -fill both -expand 1 -padx 16
        my ShowInspector
    }

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
    method PopulateParts {} {
        variable ::schem::gui::T
        if {![winfo exists $Parts]} return
        $Parts delete all
        set w [winfo width $Parts] ; if {$w < 20} { set w 232 }
        set ::schem::gui::_binY 4
        set q [string tolower [string trim $BinQuery]]
        if {$q eq "search parts"} { set q "" }   ;# ignore the placeholder text
        set shown 0

        # basic elements
        if {$BinCat in {all basics}} {
            set basics {
                battery "Battery"  vsource "AC source"  ground "Ground"
                resistor "Resistor"  capacitor "Capacitor"  inductor "Inductor"
                diode "Diode"  bjt "Transistor"  mosfet "MOSFET"
                switch "Switch"  button "Button"  relay "Relay"
                lamp "Lamp"  fuse "Fuse"
            }
            set rows {}
            foreach {type label} $basics {
                if {$q eq "" || [string match *$q* [string tolower $label]] || [string match *$q* $type]} {
                    lappend rows $type $label
                }
            }
            if {[llength $rows]} {
                my BinCategory "Basic elements"
                foreach {type label} $rows { my BinRow $type $label "" "" ; incr shown }
            }
        }

        # real parts by category
        foreach cat [::schem::parts::categories] {
            if {$BinCat ni [list all $cat]} continue
            set rows {}
            foreach id [::schem::parts::byCategory $cat] {
                set spec [::schem::parts::get $id]
                set hay [string tolower "$id [dict get $spec desc]"]
                if {$q eq "" || [string match *$q* $hay]} {
                    lappend rows [list $id $spec]
                }
            }
            if {[llength $rows]} {
                my BinCategory [my TitleCase $cat]
                foreach r $rows {
                    lassign $r id spec
                    my BinRow [dict get $spec type] $id [dict get $spec desc] $id
                    incr shown
                }
            }
        }

        if {$shown == 0} {
            $Parts create text [expr {$w/2}] 40 -text "No parts match “$BinQuery”" \
                -fill $T(faint) -font $::schem::gui::FONTSM -anchor n
            set ::schem::gui::_binY 80
        }
        $Parts configure -scrollregion [list 0 0 $w [expr {$::schem::gui::_binY+8}]]
        $Parts yview moveto 0
    }

    method TitleCase {s} {
        set out {}
        foreach w [split [string map {- " "} $s] " "] {
            lappend out [string toupper [string index $w 0]][string range $w 1 end]
        }
        return [join $out " "]
    }

    method BinCategory {name} {
        variable ::schem::gui::T
        set y $::schem::gui::_binY
        incr y 6
        $Parts create text 14 [expr {$y+8}] -text [string toupper $name] -anchor w \
            -fill $T(faint) -font {"DejaVu Sans" 8 bold}
        $Parts create line 14 [expr {$y+22}] 234 [expr {$y+22}] -fill $T(edge)
        set ::schem::gui::_binY [expr {$y+30}]
    }

    # BinRow -- one selectable row: a small symbol preview + label (+ part id).
    #   type  : schem primitive (for the symbol)
    #   label : display name
    #   desc  : datasheet one-liner (real parts; "" for primitives)
    #   partid: catalog id ("" for a primitive)
    method BinRow {type label desc partid} {
        variable ::schem::gui::T
        set y $::schem::gui::_binY
        set h 42
        set tag "row[incr ::schem::gui::_binN]"
        set bgid [::schem::gui::roundrect $Parts 8 $y 242 [expr {$y+$h-4}] 7 \
            -fill $T(surface) -outline "" -tags [list $tag bg]]
        set cy [expr {$y+($h-4)/2}]
        # drag-grip dots on the far left -- the universal "grab me" affordance
        set gx 17
        foreach dy {-6 0 6} {
            foreach dx {0 4} {
                $Parts create oval [expr {$gx+$dx-1}] [expr {$cy+$dy-1}] \
                    [expr {$gx+$dx+1}] [expr {$cy+$dy+1}] -fill $T(faint) -outline "" \
                    -tags [list $tag grip_$tag]
            }
        }
        # symbol preview
        set cx 48
        ::schem::sym::draw $Parts $type $cx $cy -scale 0.42 -standard $Std \
            -color $T(symbol) -tags $tag
        if {$partid ne ""} {
            $Parts create text 72 [expr {$cy-6}] -text $partid -anchor w \
                -fill $T(ink) -font {"DejaVu Sans" 9 bold} -tags $tag
            $Parts create text 72 [expr {$cy+8}] -text [my ShortDesc $desc] -anchor w \
                -fill $T(dim) -font {"DejaVu Sans" 8} -tags $tag
        } else {
            $Parts create text 72 $cy -text $label -anchor w \
                -fill $T(ink) -font {"DejaVu Sans" 10} -tags $tag
        }
        # what this row places
        if {$partid ne ""} { set place [list part $partid] } else { set place [list primitive $type] }
        # click = arm placement; press-drag = drag-and-drop onto the canvas
        $Parts bind $tag <Button-1>  [my callback BinPress $place %X %Y]
        $Parts bind $tag <B1-Motion> [my callback BinMotion %X %Y]
        $Parts bind $tag <ButtonRelease-1> [my callback BinDrop %X %Y]
        $Parts bind $tag <Enter> [list $Parts itemconfigure $bgid -fill $T(hover)]
        $Parts bind $tag <Leave> [list $Parts itemconfigure $bgid -fill $T(surface)]
        set ::schem::gui::_binY [expr {$y+$h}]
    }

    # ShortDesc -- trim a datasheet line to the headline (before the "--").
    method ShortDesc {d} {
        set i [string first " -- " $d]
        if {$i > 0} { return [string range $d 0 [expr {$i-1}]] }
        return $d
    }

    # PickPrimitive / PickPart -- arm placement of the chosen part; the next
    # canvas click drops it.
    method PickPrimitive {type} {
        set Pending [list primitive $type]
        my SetStatus "Click the board to place this ${type}." "+ $type"
    }
    method PickPart {id} {
        set Pending [list part $id]
        my SetStatus "Click the board to place ${id}." "+ $id"
    }

    # ----- drag-and-drop from the parts bin --------------------------------
    # Press on a bin row arms placement and records the start; dragging shows a
    # floating ghost of the symbol that follows the cursor; releasing over the
    # canvas drops the part there.  A click without a drag still arms placement
    # (so click-then-click works too).
    method BinPress {place X Y} {
        lassign $place kind what
        if {$kind eq "part"} { my PickPart $what } else { my PickPrimitive $what }
        set type [expr {$kind eq "part" ? [dict get [::schem::parts::get $what] type] : $what}]
        set Drag [dict create type $type started 0 X $X Y $Y]
    }
    method BinMotion {X Y} {
        if {$Drag eq ""} return
        # only treat as a drag once the pointer has moved a little
        if {![dict get $Drag started]} {
            if {abs($X-[dict get $Drag X]) + abs($Y-[dict get $Drag Y]) < 5} return
            dict set Drag started 1
        }
        my DrawDragGhost $X $Y
    }
    method BinDrop {X Y} {
        if {$Drag eq ""} return
        set started [dict get $Drag started]
        my KillDragGhost
        if {$started} {
            # dropped: if over the canvas, place there
            set cw $Canvas
            set cx [expr {$X - [winfo rootx $cw]}]
            set cy [expr {$Y - [winfo rooty $cw]}]
            if {$cx >= 0 && $cy >= 0 && $cx < [winfo width $cw] && $cy < [winfo height $cw]} {
                my OnClick [$Canvas canvasx $cx] [$Canvas canvasy $cy]
            }
        }
        set Drag ""
    }
    # a small floating toplevel that mirrors the dragged symbol under the cursor
    method DrawDragGhost {X Y} {
        variable ::schem::gui::T
        set g .dragghost
        if {![winfo exists $g]} {
            toplevel $g -bg $T(accent)
            wm overrideredirect $g 1
            catch {wm attributes $g -alpha 0.85}
            canvas $g.c -width 80 -height 56 -bg $T(raised) -highlightthickness 1 \
                -highlightbackground $T(accent)
            pack $g.c
            ::schem::sym::draw $g.c [dict get $Drag type] 40 28 -scale 0.7 \
                -standard $Std -color $T(ink)
        }
        wm geometry $g +[expr {$X+12}]+[expr {$Y+12}]
        raise $g
    }
    method KillDragGhost {} { catch {destroy .dragghost} }

    method SetTool {t} { set Tool $t ; set PendWire "" ; my SetStatus "Tool: $t" ; my DrawToolbar ; my Redraw }

    # ----- zoom ------------------------------------------------------------
    method ZoomIn  {} { my SetZoom [expr {$Zoom*1.25}] }
    method ZoomOut {} { my SetZoom [expr {$Zoom/1.25}] }
    method ZoomReset {} { my SetZoom 1.0 }
    # FitToContent -- choose a zoom so the whole board fits the viewport.
    method FitToContent {} {
        if {[dict size $Placed] == 0} { my SetZoom 1.0 ; return }
        set minx 1e9 ; set miny 1e9 ; set maxx -1e9 ; set maxy -1e9
        dict for {n pl} $Placed {
            set x [dict get $pl x] ; set y [dict get $pl y]
            if {$x < $minx} { set minx $x } ; if {$x > $maxx} { set maxx $x }
            if {$y < $miny} { set miny $y } ; if {$y > $maxy} { set maxy $y }
        }
        set bw [expr {($maxx-$minx)+200}] ; set bh [expr {($maxy-$miny)+200}]
        set vw [winfo width $Canvas] ; set vh [winfo height $Canvas]
        if {$vw < 50} { set vw 900 } ; if {$vh < 50} { set vh 600 }
        set z [expr {min(double($vw)/$bw, double($vh)/$bh)}]
        my SetZoom $z
    }
    method SetZoom {z} {
        if {$z < 0.35} { set z 0.35 } ; if {$z > 3.0} { set z 3.0 }
        set Zoom $z
        my Redraw
        my SetStatus "Zoom [expr {round($Zoom*100)}]%"
    }
    # Zoom toward the cursor on wheel scroll.
    method WheelZoom {dir x y} {
        set wx [expr {$x/$Zoom}] ; set wy [expr {$y/$Zoom}]
        my SetZoom [expr {$dir > 0 ? $Zoom*1.15 : $Zoom/1.15}]
    }

    # ----- the canvas: grid, symbols, wires, probes ------------------------
    method Redraw {} {
        variable ::schem::gui::T
        if {![winfo exists $Canvas]} return
        $Canvas delete all
        my DrawGrid
        if {[dict size $Placed] == 0} {
            my DrawWelcome
        } else {
            foreach w $Wires { my DrawWire $w }
            dict for {name pl} $Placed { my DrawComponent $name }
            if {$Sel ne "" && [dict exists $Placed $Sel]} { my DrawSelection $Sel }
        }
        my DrawZoomControl   ;# always on top
    }

    # A floating control cluster in the bottom-right of the canvas: zoom out,
    # the current percentage (click to reset to 100%), and zoom in.  Drawn as
    # canvas items pinned to the viewport so it stays put while you pan/zoom.
    method DrawZoomControl {} {
        variable ::schem::gui::T
        $Canvas delete zoomctl
        set vx [winfo width $Canvas] ; set vy [winfo height $Canvas]
        if {$vx < 50} { set vx 1000 } ; if {$vy < 50} { set vy 700 }
        # convert viewport corner to canvas coords (so it ignores scroll)
        set ox [$Canvas canvasx [expr {$vx-16}]] ; set oy [$Canvas canvasy [expr {$vy-16}]]
        set bw 34 ; set bh 30 ; set gap 4
        set pctw 56
        set totalw [expr {$bw*2+$pctw+$gap*2}]
        set x0 [expr {$ox-$totalw}] ; set y0 [expr {$oy-$bh}]
        # container shadow/panel
        ::schem::gui::roundrect $Canvas [expr {$x0-2}] [expr {$y0-2}] [expr {$ox+2}] [expr {$oy+2}] 9 \
            -fill $T(surface) -outline $T(edge) -tags zoomctl
        # minus button
        my ZoomBtn zoom_out $x0 $y0 [expr {$x0+$bw}] [expr {$y0+$bh}] "−"
        # percentage (click = reset)
        set px0 [expr {$x0+$bw+$gap}]
        ::schem::gui::roundrect $Canvas $px0 $y0 [expr {$px0+$pctw}] [expr {$y0+$bh}] 6 \
            -fill $T(surface) -outline "" -tags {zoomctl zc_reset}
        $Canvas create text [expr {$px0+$pctw/2}] [expr {$y0+$bh/2}] \
            -text "[expr {round($Zoom*100)}]%" -fill $T(dim) -font $::schem::gui::FONTSM \
            -tags {zoomctl zc_reset}
        $Canvas bind zc_reset <Button-1> [my callback ZoomReset]
        # plus button
        set bx0 [expr {$px0+$pctw+$gap}]
        my ZoomBtn zoom_in $bx0 $y0 [expr {$bx0+$bw}] [expr {$y0+$bh}] "+"
    }
    method ZoomBtn {which x1 y1 x2 y2 glyph} {
        variable ::schem::gui::T
        set tag "zc_$which"
        set id [::schem::gui::roundrect $Canvas $x1 $y1 $x2 $y2 6 -fill $T(raised) -outline "" \
            -tags [list zoomctl $tag]]
        $Canvas create text [expr {($x1+$x2)/2}] [expr {($y1+$y2)/2}] -text $glyph \
            -fill $T(ink) -font {"DejaVu Sans" 15} -tags [list zoomctl $tag]
        set cmd [expr {$which eq "zoom_in" ? [my callback ZoomIn] : [my callback ZoomOut]}]
        $Canvas bind $tag <Button-1> $cmd
        $Canvas bind $tag <Enter> [list $Canvas itemconfigure $id -fill $T(hover)]
        $Canvas bind $tag <Leave> [list $Canvas itemconfigure $id -fill $T(raised)]
    }

    # DrawWelcome -- the empty-board hint: a quiet pointer to the workflow, so a
    # first-time user (or an EE sizing the tool up) knows exactly what to do.
    method DrawWelcome {} {
        variable ::schem::gui::T
        lassign [my CanvasSize] W H
        set cx [expr {$W/2}] ; set cy [expr {$H/2 - 40}]
        $Canvas create text $cx $cy -text "Build a circuit" -fill $T(dim) \
            -font {TkDefaultFont 20 bold} -tags welcome
        set lines {
            "1.  Click a part in the bin on the left"
            "2.  Click the canvas to place it"
            "3.  Wire tool: click a pin, then another pin"
            "4.  Solve (F5), then Probe nodes"
            "5.  Design review checks parts vs datasheet ratings"
            "6.  Manufacture -> Export PCB (KiCad + BOM)"
        }
        set y [expr {$cy + 44}]
        foreach ln $lines {
            $Canvas create text $cx $y -text $ln -fill $T(faint) \
                -font {TkDefaultFont 11} -tags welcome
            incr y 26
        }
    }

    # A dot grid -- a dot at each snap point, brighter on the major (5-grid)
    # intersections.  Cleaner and less busy than ruled lines, the way modern
    # design/EDA canvases look.
    method DrawGrid {} {
        variable ::schem::gui::T
        lassign [my CanvasSize] W H
        set g [expr {$Grid*$Zoom}]
        if {$g < 6} { set g [expr {$g*2}] }   ;# avoid a too-dense dot field
        set major 0
        for {set x 0} {$x <= $W} {set x [expr {$x+$g}]} {
            set cxmaj [expr {round($x/$g) % 5 == 0}]
            for {set y 0} {$y <= $H} {set y [expr {$y+$g}]} {
                set maj [expr {$cxmaj && (round($y/$g) % 5 == 0)}]
                if {$maj} { set c $T(gridcross) ; set r 1.4 } else { set c $T(griddot) ; set r 0.9 }
                $Canvas create oval [expr {$x-$r}] [expr {$y-$r}] [expr {$x+$r}] [expr {$y+$r}] \
                    -fill $c -outline "" -tags grid
            }
        }
    }

    method CanvasSize {} {
        set W [winfo width $Canvas] ; set H [winfo height $Canvas]
        if {$W < 10} { set W 1000 } ; if {$H < 10} { set H 700 }
        return [list [expr {max($W,1400)}] [expr {max($H,1000)}]]
    }

    # DrawComponent -- render a placed part's schematic symbol + pin dots, and
    # record the absolute pin coordinates for wiring.
    method DrawComponent {name} {
        variable ::schem::gui::T
        set pl [dict get $Placed $name]
        set type [dict get $pl type]
        set x [expr {[dict get $pl x]*$Zoom}] ; set y [expr {[dict get $pl y]*$Zoom}]
        set rot [dict get $pl rot]
        set partid [dict get $pl partid]
        set val [my ValueText $name]
        set color [my ComponentColor $name]
        set sym [::schem::sym::draw $Canvas $type $x $y -scale [expr {1.2*$Zoom}] -standard $Std \
            -rot $rot -tags [list comp comp_$name] -color $color -label $name -value $val]
        # pin dots + record absolute positions
        set abspins [dict create]
        dict for {pin off} [dict get $sym pins] {
            lassign $off dx dy
            set px [expr {$x+$dx}] ; set py [expr {$y+$dy}]
            dict set abspins $pin [list $px $py]
            $Canvas create oval [expr {$px-3}] [expr {$py-3}] [expr {$px+3}] [expr {$py+3}] \
                -fill $T(surface) -outline $T(dim) -width 1 -tags [list pin pin_${name}_$pin]
            $Canvas bind pin_${name}_$pin <Enter> [my callback HoverPin $name $pin]
        }
        dict set Placed $name pinabs $abspins
        # probe voltage overlay after a solve
        if {$Result eq "solved"} { my DrawProbe $name $abspins }
    }

    method ComponentColor {name} {
        variable ::schem::gui::T
        # after a design review, colour over-limit parts red, marginal amber
        if {[dict exists $Placed $name verdict]} {
            switch [dict get $Placed $name verdict] {
                over     { return $T(bad) }
                marginal { return $T(warn) }
            }
        }
        return $T(ink)
    }

    method ValueText {name} {
        set pl [dict get $Placed $name]
        if {[dict get $pl partid] ne ""} { return [dict get $pl partid] }
        set type [dict get $pl type]
        if {[catch {$S get $name} params]} { return "" }
        return [::schem::pcb::value $type $params]
    }

    method DrawWire {w} {
        variable ::schem::gui::T
        lassign $w a b
        lassign [my PinXY $a] ax ay
        lassign [my PinXY $b] bx by
        if {$ax eq "" || $bx eq ""} return
        set col $T(wire)
        if {$Result eq "solved"} { set col [my NetColor $a] }
        # orthogonal route: horizontal then vertical (manhattan)
        $Canvas create line $ax $ay $bx $ay $bx $by -fill $col -width 2 \
            -tags [list wire] -joinstyle round
        # junction dot at the bend
        $Canvas create oval [expr {$bx-2}] [expr {$ay-2}] [expr {$bx+2}] [expr {$ay+2}] \
            -fill $col -outline $col -tags wire
    }

    method PinXY {term} {
        lassign [split $term .] name pin
        if {![dict exists $Placed $name pinabs $pin]} { return {{} {}} }
        return [dict get $Placed $name pinabs $pin]
    }

    method DrawSelection {name} {
        variable ::schem::gui::T
        set bb [$Canvas bbox comp_$name]
        if {$bb eq ""} return
        lassign $bb x1 y1 x2 y2
        $Canvas create rectangle [expr {$x1-4}] [expr {$y1-4}] [expr {$x2+4}] [expr {$y2+4}] \
            -outline $T(sel) -width 1 -dash {3 2} -tags selhalo
    }

    method DrawProbe {name abspins} {
        variable ::schem::gui::T
        # show node voltage at the first pin
        dict for {pin xy} $abspins {
            lassign $xy px py
            if {[catch {$S probe $name.$pin} v]} continue
            $Canvas create text [expr {$px+6}] [expr {$py-8}] -text [format "%.2gV" $v] \
                -fill $T(probe) -font {TkFixedFont 8} -anchor w -tags probe
            break
        }
    }

    method NetColor {term} {
        variable ::schem::gui::T
        if {[catch {$S probe $term} v]} { return $T(wire) }
        if {$v > 6} { return $T(wirelive) }
        return $T(wire)
    }

    # ----- interaction -----------------------------------------------------
    method OnClick {x y} {
        # placement / selection work in WORLD coords (snapped); wiring/probe use
        # screen coords directly (pins are stored in screen space).
        if {$Pending ne ""} { my PlacePending [my SnapW $x] [my SnapW $y] ; return }
        switch -- $Tool {
            select { my SelectAt [my SnapW $x] [my SnapW $y] }
            wire   { my WireClick $x $y }
            probe  { my ProbeAt $x $y }
        }
    }

    # SnapW -- screen pixel -> snapped WORLD coordinate.
    method SnapW {v} { expr {round(double($v)/$Zoom/$Grid)*$Grid} }
    method Snap {v} { expr {round(double($v)/$Grid)*$Grid} }

    method PlacePending {x y} {
        lassign $Pending kind what
        set type [expr {$kind eq "primitive" ? $what : [dict get [::schem::parts::get $what] type]}]
        set name [my AutoName $type]
        if {$kind eq "primitive"} {
            $S add $type $name
            set partid ""
        } else {
            ::schem::parts::place $S $name $what
            set partid $what
        }
        dict set Placed $name [dict create type $type x $x y $y rot 0 partid $partid pinabs {}]
        set Pending ""
        set Sel $name
        set Dirty 1 ; set Result none
        my Redraw ; my ShowInspector
        my SetStatus "Placed $name.  Wire its pins, or place another part."
    }

    method AutoName {type} {
        set prefix [string toupper [string index $type 0]]
        if {[info exists ::schem::pcb::MAP] && [dict exists [array get ::schem::pcb::MAP] $type]} {}
        catch { set prefix [dict get $::schem::pcb::MAP($type) prefix] }
        dict incr Counter $prefix
        set n "$prefix[dict get $Counter $prefix]"
        while {[dict exists $Placed $n]} { dict incr Counter $prefix ; set n "$prefix[dict get $Counter $prefix]" }
        return $n
    }

    method SelectAt {x y} {
        set hit [my ComponentAt $x $y]
        set Sel $hit
        my Redraw ; my ShowInspector
        if {$hit ne ""} { my SetStatus "Selected $hit" } else { my SetStatus "Ready" }
    }

    # ComponentAt -- nearest component to a WORLD-coordinate point.
    method ComponentAt {x y} {
        set best "" ; set bestd 1e9
        set tol [expr {2500}]
        dict for {name pl} $Placed {
            set dx [expr {$x-[dict get $pl x]}] ; set dy [expr {$y-[dict get $pl y]}]
            set d [expr {$dx*$dx+$dy*$dy}]
            if {$d < $bestd && $d < $tol} { set bestd $d ; set best $name }
        }
        return $best
    }

    # wiring: first click selects a start pin, second click a finish pin
    method WireClick {x y} {
        set pin [my NearestPin $x $y]
        if {$pin eq ""} { my SetStatus "Click on a component pin to start a wire." ; return }
        if {$PendWire eq ""} {
            set PendWire $pin
            my SetStatus "Wire from $pin -- click the destination pin." "wiring: $pin"
        } else {
            if {$pin ne $PendWire} {
                $S wire $PendWire $pin
                lappend Wires [list $PendWire $pin]
                set Dirty 1 ; set Result none
                my SetStatus "Wired $PendWire -> $pin"
            }
            set PendWire ""
            my Redraw
        }
    }

    # AddWire -- wire two terminals by name (model + canvas), for scripting and
    # the load path.  Skips if either endpoint isn't a placed component.
    method AddWire {a b} {
        if {[catch {$S wire $a $b} err]} { my SetStatus "wire error: $err" ; return 0 }
        lappend Wires [list $a $b]
        set Dirty 1 ; set Result none
        my Redraw
        return 1
    }

    method NearestPin {x y} {
        set best "" ; set bestd 1e9
        dict for {name pl} $Placed {
            dict for {pin xy} [dict get $pl pinabs] {
                lassign $xy px py
                set d [expr {($x-$px)**2 + ($y-$py)**2}]
                if {$d < $bestd && $d < 400} { set bestd $d ; set best $name.$pin }
            }
        }
        return $best
    }

    method ProbeAt {x y} {
        if {$Result ne "solved"} { my SetStatus "Solve first (F5), then probe." ; return }
        set pin [my NearestPin $x $y]
        if {$pin eq ""} { return }
        if {[catch {$S probe $pin} v]} { my SetStatus "no node at $pin" ; return }
        my SetStatus "Probe $pin = [format %.4g $v] V" "$pin = [format %.4g $v] V"
    }

    method HoverPin {name pin} {
        my SetStatus "pin $name.$pin" ""
    }

    method OnDrag {x y} {
        # drag the selected component (world coords)
        if {$Tool ne "select" || $Sel eq "" || $Pending ne ""} return
        dict set Placed $Sel x [my SnapW $x] ; dict set Placed $Sel y [my SnapW $y]
        set Dirty 1
        my Redraw
    }
    method OnRelease {x y} {}

    method OnHover {x y} {
        if {$Tool eq "wire" && $PendWire ne ""} {
            $Canvas delete rubber
            lassign [my PinXY $PendWire] px py
            if {$px ne ""} {
                $Canvas create line $px $py $x $y -fill $::schem::gui::T(sel) -dash {2 2} -tags rubber
            }
        }
    }

    method OnRightClick {x y} {
        set hit [my ComponentAt [my SnapW $x] [my SnapW $y]]
        if {$hit ne ""} { set Sel $hit ; my Redraw ; my ShowInspector }
    }

    # ----- inspector -------------------------------------------------------
    method ShowInspector {} {
        variable ::schem::gui::T
        if {![info exists Insp] || ![winfo exists $Insp]} return
        foreach c [winfo children $Insp] { destroy $c }
        if {$Sel eq "" || ![dict exists $Placed $Sel]} {
            label $Insp.none -text "Nothing selected" -bg $T(surface) -fg $T(dim) \
                -justify left -anchor nw -font $::schem::gui::FONT
            pack $Insp.none -fill x -anchor nw
            label $Insp.hint2 -text "Click a part on the board to\nedit its values and ratings." \
                -bg $T(surface) -fg $T(faint) -justify left -anchor nw -font $::schem::gui::FONTSM
            pack $Insp.hint2 -fill x -anchor nw -pady {4 0}
            my ShowBoardSummary
            return
        }
        set pl [dict get $Placed $Sel]
        set type [dict get $pl type] ; set partid [dict get $pl partid]
        # name + type, on one tidy header line
        label $Insp.name -text $Sel -bg $T(surface) -fg $T(ink) \
            -font {"DejaVu Sans" 15 bold} -anchor w
        pack $Insp.name -fill x -anchor w
        if {$partid ne ""} {
            set spec [::schem::parts::get $partid]
            label $Insp.type -text "$partid  ·  [dict get $spec mfr]" -bg $T(surface) \
                -fg $T(accent) -anchor w -font $::schem::gui::FONTSM
            pack $Insp.type -fill x -anchor w
            label $Insp.pdesc -text [my ShortDesc [dict get $spec desc]] -bg $T(surface) \
                -fg $T(dim) -anchor w -wraplength 250 -justify left -font $::schem::gui::FONTSM
            pack $Insp.pdesc -fill x -anchor w -pady {2 0}
        } else {
            label $Insp.type -text $type -bg $T(surface) -fg $T(accent) -anchor w \
                -font $::schem::gui::FONTSM
            pack $Insp.type -fill x -anchor w
        }
        if {![catch {$S get $Sel} params] && [dict size $params]} {
            my InspSection $Insp.ph "Values"
            set i 0
            dict for {k v} $params {
                set row [frame $Insp.p$i -bg $T(surface)]
                pack $row -fill x -anchor w -pady 2
                label $row.k -text $k -bg $T(surface) -fg $T(dim) -width 7 -anchor w \
                    -font $::schem::gui::FONTSM
                pack $row.k -side left
                set ev [entry $row.v -bg $T(raised) -fg $T(ink) -insertbackground $T(accent) \
                    -relief flat -font $::schem::gui::FONTMONO -highlightthickness 1 \
                    -highlightbackground $T(edge) -highlightcolor $T(accent)]
                $ev insert 0 $v
                pack $ev -side left -fill x -expand 1 -ipady 2
                bind $ev <Return>   [my callback SetParam $Sel $k $ev]
                bind $ev <FocusOut> [my callback SetParam $Sel $k $ev]
                incr i
            }
        }
        if {[dict exists $pl ratings]} { my ShowRatings [dict get $pl ratings] }
    }

    # InspSection -- a small section header with a hairline rule.
    method InspSection {w title} {
        variable ::schem::gui::T
        set f [frame $w -bg $T(surface)]
        pack $f -fill x -anchor w -pady {12 4}
        label $f.l -text [string toupper $title] -bg $T(surface) -fg $T(faint) \
            -font {"DejaVu Sans" 8 bold} -anchor w
        pack $f.l -side top -fill x -anchor w
        frame $f.r -bg $T(edge) -height 1
        pack $f.r -side top -fill x -pady {3 0}
    }

    method ShowRatings {findings} {
        variable ::schem::gui::T
        my InspSection $Insp.rh "Ratings"
        set i 0
        foreach r $findings {
            set col [dict get [list over $T(bad) marginal $T(warn) ok $T(good)] [dict get $r verdict]]
            set row [frame $Insp.r$i -bg $T(surface)]
            pack $row -fill x -anchor w -pady 1
            # a small status dot + the limit name + the measured/rated figure
            canvas $row.d -width 10 -height 10 -bg $T(surface) -highlightthickness 0
            $row.d create oval 2 2 8 8 -fill $col -outline ""
            pack $row.d -side left -padx {0 6}
            label $row.l -text [dict get $r limit] -bg $T(surface) -fg $T(ink) \
                -width 5 -anchor w -font $::schem::gui::FONTSM
            pack $row.l -side left
            set pct [format %.0f [expr {[dict get $r margin]*100}]]
            label $row.v -text "${pct}%" -bg $T(surface) -fg $col -width 5 -anchor w \
                -font {"DejaVu Sans" 9 bold}
            pack $row.v -side left
            label $row.f -text [format "%.3g/%.3g%s" [dict get $r measured] \
                [dict get $r rating] [dict get $r unit]] -bg $T(surface) -fg $T(faint) \
                -anchor w -font $::schem::gui::FONTMONO
            pack $row.f -side left
            incr i
        }
    }

    method ShowBoardSummary {} {
        variable ::schem::gui::T
        my InspSection $Insp.bs "Board"
        label $Insp.sum -text "[dict size $Placed] parts · [llength $Wires] wires" \
            -bg $T(surface) -fg $T(dim) -anchor w -font $::schem::gui::FONTSM
        pack $Insp.sum -fill x -anchor w
        if {[dict size $Placed] > 0 && $Result ne "solved"} {
            label $Insp.hint -text "Press F5 to solve." \
                -bg $T(surface) -fg $T(faint) -anchor w -font $::schem::gui::FONTSM
            pack $Insp.hint -fill x -anchor w -pady {4 0}
        } elseif {$Result eq "solved"} {
            label $Insp.solved -text "Solved — probe nodes, or run a Design review." -bg $T(surface) \
                -fg $T(good) -anchor w -wraplength 250 -justify left -font $::schem::gui::FONTSM
            pack $Insp.solved -fill x -anchor w
        }
    }

    method SetParam {name key entry} {
        if {![winfo exists $entry]} return
        set v [$entry get]
        if {[catch {$S set $name $key $v} err]} { my SetStatus "bad value for $key: $err" ; return }
        set Dirty 1 ; set Result none
        my Redraw
        my SetStatus "$name.$key = $v"
    }

    # ----- commands --------------------------------------------------------
    method Cmd {what args} {
        switch -- $what {
            new        { my CmdNew }
            open       { my CmdOpen }
            save       { my CmdSave }
            saveas     { my CmdSaveAs }
            export_svg { my CmdExportSvg }
            export_pcb { my CmdExportPcb }
            quit       { my CmdQuit }
            delete     { my CmdDelete }
            rotate     { my CmdRotate }
            clear      { my CmdClear }
            togglestd  { set Std [expr {$Std eq "ansi" ? "iec" : "ansi"}] ; my DrawToolbar ; my PopulateParts ; my Redraw ; my SetStatus "symbols: $Std" }
            fit        { my Redraw }
            solve      { my CmdSolve }
            transient  { my CmdTransient }
            clearresults { set Result none ; my Redraw ; my SetStatus "results cleared" }
            review     { my CmdReview }
            validate   { my CmdValidate }
            netlist    { my CmdNetlist }
            compile    { my CmdCompile }
            fitall     { my CmdFitAll }
            zoomin     { my ZoomIn }
            zoomout    { my ZoomOut }
            zoomreset  { my ZoomReset }
            help       { my CmdHelp }
            about      { my CmdAbout }
        }
    }

    method CmdNew {} {
        catch {$S destroy}
        set S [::schem::new untitled]
        set Placed [dict create] ; set Wires {} ; set Sel "" ; set Counter [dict create]
        set File "" ; set Dirty 0 ; set Result none
        my Redraw ; my ShowInspector ; my SetStatus "New board."
    }

    method CmdDelete {} {
        if {$Sel eq ""} { my SetStatus "Nothing selected." ; return }
        # remove wires touching it
        set kept {}
        foreach w $Wires {
            lassign $w a b
            if {[lindex [split $a .] 0] eq $Sel || [lindex [split $b .] 0] eq $Sel} continue
            lappend kept $w
        }
        set Wires $kept
        catch {$S remove $Sel}
        set Placed [dict remove $Placed $Sel]
        my SetStatus "Deleted $Sel"
        set Sel "" ; set Dirty 1 ; set Result none
        my Redraw ; my ShowInspector
    }

    method CmdRotate {} {
        if {$Sel eq ""} { my SetStatus "Select a part to rotate." ; return }
        set r [expr {([dict get $Placed $Sel rot] + 90) % 360}]
        dict set Placed $Sel rot $r
        set Dirty 1
        my Redraw
        my SetStatus "$Sel rotated to ${r} deg"
    }

    method CmdClear {} {
        set Placed [dict create] ; set Wires {} ; set Sel ""
        catch {$S destroy} ; set S [::schem::new untitled]
        set Result none ; set Dirty 1
        my Redraw ; my ShowInspector ; my SetStatus "Board cleared."
    }

    method CmdSolve {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to solve." ; return }
        if {[catch {$S solve} err]} { my SetStatus "solve error: $err" ; return }
        set Result solved
        set f [$S faults]
        my Redraw ; my ShowInspector
        if {[llength $f]} {
            my SetStatus "Solved with [llength $f] fault(s): [dict get [lindex $f 0] detail]"
        } else {
            my SetStatus "Solved.  Probe nodes, or run a Design review." "OK"
        }
    }

    # TextDialog -- a reusable scrollable, monospace, read-only text window for
    # the netlist, the validation report, the compiled output, etc.  Optionally
    # offers a "Save..." button writing the body to a file.
    method TextDialog {title body {savext ""}} {
        variable ::schem::gui::T
        set w .td[incr ::schem::gui::_wincount]
        toplevel $w -bg $T(surface)
        wm title $w $title
        catch {wm geometry $w 720x520}
        label $w.h -text $title -bg $T(surface) -fg $T(ink) -anchor w \
            -font $::schem::gui::FONTTITLE -padx 14
        pack $w.h -side top -fill x -pady {12 6}
        set tf [frame $w.tf -bg $T(surface)]
        pack $tf -side top -fill both -expand 1 -padx 12
        set txt [text $tf.t -bg $T(sunken) -fg $T(ink) -bd 0 -highlightthickness 0 \
            -wrap none -padx 10 -pady 8 -font $::schem::gui::FONTMONO \
            -yscrollcommand [list $tf.sb set] -xscrollcommand [list $tf.hb set] \
            -insertbackground $T(accent)]
        scrollbar $tf.sb -orient vertical -command [list $txt yview] \
            -bg $T(edgehi) -activebackground $T(accent) -troughcolor $T(sunken) \
            -bd 0 -highlightthickness 0 -width 13
        scrollbar $tf.hb -orient horizontal -command [list $txt xview] \
            -bg $T(edgehi) -activebackground $T(accent) -troughcolor $T(sunken) \
            -bd 0 -highlightthickness 0 -width 13
        grid $txt    -row 0 -column 0 -sticky nsew
        grid $tf.sb  -row 0 -column 1 -sticky ns
        grid $tf.hb  -row 1 -column 0 -sticky ew
        grid rowconfigure $tf 0 -weight 1
        grid columnconfigure $tf 0 -weight 1
        $txt insert end $body
        $txt configure -state disabled
        # button row
        set bb [frame $w.bb -bg $T(surface)]
        pack $bb -side bottom -fill x -padx 12 -pady 10
        button $bb.close -text "Close" -command [list destroy $w] \
            -bg $T(raised) -fg $T(ink) -activebackground $T(hover) -relief flat -padx 14 -pady 5
        pack $bb.close -side right
        if {$savext ne ""} {
            button $bb.save -text "Save…" -relief flat -padx 14 -pady 5 \
                -bg $T(accent2) -fg white -activebackground $T(accent) \
                -command [my callback DialogSave $body $savext]
            pack $bb.save -side right -padx {0 8}
        }
        return $w
    }
    method DialogSave {body ext} {
        set f [tk_getSaveFile -defaultextension $ext]
        if {$f eq ""} return
        set fh [open $f w] ; puts $fh $body ; close $fh
        my SetStatus "Saved $f"
    }

    # CmdValidate -- run the anti-spaghetti + electrical design-rule checks and
    # show the report (the DRC an engineer runs before committing a board).
    method CmdValidate {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to validate." ; return }
        my SyncPositions
        set rep [$S validateText]
        set findings [$S validate]
        my TextDialog "Design-rule check" $rep
        if {[llength $findings]} {
            my SetStatus "[llength $findings] design-rule finding(s)." "WARN"
        } else {
            my SetStatus "Design-rule check passed." "OK"
        }
    }

    # CmdNetlist -- show the derived netlist (nodes + elements), the connectivity
    # the simulator and exporters consume.
    method CmdNetlist {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to net." ; return }
        my SyncPositions
        my TextDialog "Netlist (derived)" [$S netlistText] .txt
        my SetStatus "Netlist shown."
    }

    # CmdCompile -- compile the board down to a standalone Zig program that
    # solves it, the same backend the CLI's `emit zig` uses.  This is the
    # "compile down" path: the schematic becomes native code you can build and
    # run with `zig run`.
    method CmdCompile {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to compile." ; return }
        my SyncPositions
        if {[catch {::schem::emit $S zig} src]} { my SetStatus "compile error: $src" ; return }
        set n [llength [split $src \n]]
        my TextDialog "Compiled to Zig  ·  $n lines  ·  build with: zig run FILE.zig" $src .zig
        my SetStatus "Compiled to Zig ($n lines).  Save and `zig run` it." "OK"
    }

    # CmdTransient -- time-domain analysis (for AC sources, RC/RL timing,
    # rectifier ripple, oscillators).  Asks for a duration + step, runs, and
    # plots the recorded node waveforms.
    method CmdTransient {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to run." ; return }
        my SyncPositions
        my TransientDialog
    }

    method CmdFitAll {} { my FitToContent ; my Redraw }

    # ----- transient analysis dialog ---------------------------------------
    # A time-domain run with a small controls strip (duration, step, which node
    # to plot) and a live oscilloscope-style plot.  This is what brings the AC
    # sources, RC/RL timing and rectifier ripple to life in the GUI.
    method TransientDialog {} {
        variable ::schem::gui::T
        set w .tr[incr ::schem::gui::_wincount]
        toplevel $w -bg $T(surface)
        wm title $w "Transient analysis"
        catch {wm geometry $w 760x520}
        # controls
        set ctl [frame $w.ctl -bg $T(surface)]
        pack $ctl -side top -fill x -padx 12 -pady 10
        label $ctl.dl -text "Duration (s)" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.dl -side left
        entry $ctl.de -bg $T(raised) -fg $T(ink) -width 8 -relief flat \
            -insertbackground $T(accent) -font $::schem::gui::FONTMONO
        $ctl.de insert 0 "0.05" ; pack $ctl.de -side left -padx {4 12}
        label $ctl.sl -text "Step (s)" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.sl -side left
        entry $ctl.se -bg $T(raised) -fg $T(ink) -width 8 -relief flat \
            -insertbackground $T(accent) -font $::schem::gui::FONTMONO
        $ctl.se insert 0 "5e-5" ; pack $ctl.se -side left -padx {4 12}
        label $ctl.nl -text "Plot node" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.nl -side left
        # node menu = every component terminal
        set terms {}
        foreach n [$S components] {
            if {[$S typeof $n] in {ground bus junction}} continue
            foreach t [$S terminals $n] { lappend terms $n.$t }
        }
        set nodevar ::schem::gui::_trnode$::schem::gui::_wincount
        set $nodevar [lindex $terms 0]
        set mb [menubutton $ctl.nb -textvariable $nodevar -bg $T(raised) -fg $T(ink) \
            -relief flat -padx 8 -pady 2 -font $::schem::gui::FONTMONO -direction below -indicatoron 0]
        pack $mb -side left -padx 4
        set nm [menu $mb.m -tearoff 0 -bg $T(raised) -fg $T(ink) -activebackground $T(accent2)]
        $mb configure -menu $nm
        foreach t $terms { $nm add command -label $t -command [list set $nodevar $t] }
        # plot canvas
        set plot [canvas $w.plot -bg $T(sunken) -highlightthickness 0]
        pack $plot -side top -fill both -expand 1 -padx 12 -pady {0 8}
        # buttons
        set bb [frame $w.bb -bg $T(surface)]
        pack $bb -side bottom -fill x -padx 12 -pady 10
        button $bb.run -text "Run ▶" -relief flat -padx 16 -pady 5 \
            -bg $T(accent2) -fg white -activebackground $T(accent) \
            -command [my callback RunTransient $ctl.de $ctl.se $nodevar $plot]
        pack $bb.run -side left
        button $bb.close -text "Close" -command [list destroy $w] \
            -bg $T(raised) -fg $T(ink) -activebackground $T(hover) -relief flat -padx 14 -pady 5
        pack $bb.close -side right
        after 60 [my callback RunTransient $ctl.de $ctl.se $nodevar $plot]
    }

    method RunTransient {de se nodevar plot} {
        variable ::schem::gui::T
        if {![winfo exists $plot]} return
        set dur [$de get] ; set dt [$se get] ; set node [set $nodevar]
        if {![string is double -strict $dur] || ![string is double -strict $dt]} {
            my SetStatus "transient: bad duration/step" ; return
        }
        if {[catch {$S run -duration $dur -dt $dt -record [list $node]} res]} {
            my SetStatus "transient error: $res" ; return
        }
        my PlotWave $plot [dict get $res t] [dict get $res $node] $node
        my SetStatus "Transient run: $node over ${dur}s" "OK"
    }

    # PlotWave -- a simple oscilloscope trace of v(t) with autoscaled axes.
    method PlotWave {c ts vs label} {
        variable ::schem::gui::T
        $c delete all
        update idletasks
        set W [winfo width $c] ; set H [winfo height $c]
        if {$W < 50} { set W 700 } ; if {$H < 50} { set H 360 }
        set ml 54 ; set mr 16 ; set mt 16 ; set mb 28
        set t0 [lindex $ts 0] ; set t1 [lindex $ts end]
        if {$t1 <= $t0} { set t1 [expr {$t0+1}] }
        set vmin [lindex [lsort -real $vs] 0] ; set vmax [lindex [lsort -real $vs] end]
        if {$vmax-$vmin < 1e-9} { set vmin [expr {$vmin-1}] ; set vmax [expr {$vmax+1}] }
        set pad [expr {($vmax-$vmin)*0.1}] ; set vmin [expr {$vmin-$pad}] ; set vmax [expr {$vmax+$pad}]
        set sx [list apply {{t ml W mr t0 t1} {expr {$ml+($t-$t0)/($t1-$t0)*($W-$ml-$mr)}}} {} $ml $W $mr $t0 $t1]
        # helper closures via expr inline
        set xpix {{t} { upvar 1 ml ml W W mr mr t0 t0 t1 t1 ; expr {$ml+($t-$t0)/($t1-$t0)*($W-$ml-$mr)} }}
        set ypix {{v} { upvar 1 mt mt H H mb mb vmin vmin vmax vmax ; expr {$mt+($vmax-$v)/($vmax-$vmin)*($H-$mt-$mb)} }}
        # grid + axis labels
        for {set i 0} {$i <= 4} {incr i} {
            set v [expr {$vmin+($vmax-$vmin)*$i/4.0}]
            set y [apply $ypix $v]
            $c create line $ml $y [expr {$W-$mr}] $y -fill $T(edge)
            $c create text [expr {$ml-6}] $y -text [format %.2g $v] -anchor e \
                -fill $T(dim) -font $::schem::gui::FONTSM
        }
        $c create text [expr {($ml+$W-$mr)/2}] [expr {$H-8}] -text "time (s)  ·  0 → [format %.3g $t1]" \
            -fill $T(faint) -font $::schem::gui::FONTSM
        $c create text [expr {$ml+4}] [expr {$mt+2}] -text $label -anchor nw \
            -fill $T(accent) -font $::schem::gui::FONTH
        # zero line
        if {$vmin < 0 && $vmax > 0} {
            set yz [apply $ypix 0] ; $c create line $ml $yz [expr {$W-$mr}] $yz -fill $T(edgehi)
        }
        # trace
        set pts {}
        foreach t $ts v $vs { lappend pts [apply $xpix $t] [apply $ypix $v] }
        if {[llength $pts] >= 4} {
            $c create line {*}$pts -fill $T(good) -width 2 -smooth 1
        }
    }

    method CmdReview {} {
        my CmdSolve
        set findings [::schem::ratings::check $S]
        # attach per-part findings + verdict
        set worst [dict create]
        foreach r $findings {
            set p [dict get $r part]
            dict lappend Placed_ratings $p $r
        }
        # reset verdicts
        dict for {name pl} $Placed {
            set rs [expr {[info exists Placed_ratings] && [dict exists $Placed_ratings $name] ? [dict get $Placed_ratings $name] : {}}]
            dict set Placed $name ratings $rs
            set v ok
            foreach r $rs {
                if {[dict get $r verdict] eq "over"} { set v over ; break }
                if {[dict get $r verdict] eq "marginal"} { set v marginal }
            }
            if {[llength $rs]} { dict set Placed $name verdict $v } else { dict unset Placed $name verdict }
        }
        set nover 0 ; set nmarg 0
        foreach r $findings {
            if {[dict get $r verdict] eq "over"} { incr nover }
            if {[dict get $r verdict] eq "marginal"} { incr nmarg }
        }
        my Redraw ; my ShowInspector
        if {$nover} {
            my SetStatus "Design review: $nover OVER LIMIT, $nmarg marginal -- see red parts." "FAIL"
        } elseif {$nmarg} {
            my SetStatus "Design review: $nmarg marginal (>80% of rating) -- amber parts." "WARN"
        } elseif {[llength $findings]} {
            my SetStatus "Design review: all real parts within ratings." "OK"
        } else {
            my SetStatus "No real parts placed -- nothing to review (place parts, not just primitives)."
        }
    }

    method CmdSave {} {
        if {$File eq ""} { my CmdSaveAs ; return }
        my SyncPositions
        if {[catch {::schem::save $S $File} err]} { my SetStatus "save error: $err" ; return }
        set Dirty 0
        my SetStatus "Saved $File"
    }
    method CmdSaveAs {} {
        set f [tk_getSaveFile -defaultextension .schem -filetypes {{Schematic {.schem}}}]
        if {$f eq ""} return
        set File $f ; my CmdSave
    }
    method CmdOpen {} {
        set f [tk_getOpenFile -filetypes {{Schematic {.schem}} {All *}}]
        if {$f eq ""} return
        if {[catch {::schem::load $f} ns]} { my SetStatus "open error: $ns" ; return }
        catch {$S destroy} ; set S $ns ; set File $f ; set Dirty 0 ; set Result none
        my RebuildFromSchematic
        my SetStatus "Opened $f"
    }

    # Persist current canvas positions onto the model before saving.
    method SyncPositions {} {
        dict for {name pl} $Placed {
            catch {$S place $name [expr {[dict get $pl x]/$Grid}] [expr {[dict get $pl y]/$Grid}]}
        }
    }
    # Rebuild canvas placement from a loaded schematic (positions + wires).
    method RebuildFromSchematic {} {
        set Placed [dict create] ; set Wires {}
        foreach name [$S components] {
            set a [$S attrs $name]
            set pos [dict get $a pos]
            if {$pos eq ""} { set x 200 ; set y 200 } else {
                set x [expr {int([lindex $pos 0])*$Grid + 100}]
                set y [expr {int([lindex $pos 1])*$Grid + 100}]
            }
            dict set Placed $name [dict create type [$S typeof $name] x $x y $y rot 0 \
                partid [::schem::parts::idOf $S $name] pinabs {}]
        }
        foreach co [$S conns] {
            lassign $co a b
            lappend Wires [list $a $b]
        }
        set Sel ""
        my Redraw ; my ShowInspector
    }

    method CmdExportSvg {} {
        set f [tk_getSaveFile -defaultextension .svg -filetypes {{SVG {.svg}}}]
        if {$f eq ""} return
        my SyncPositions
        if {[catch {::schem::svgFile $S $f -title [$S name]} err]} { my SetStatus "export error: $err" ; return }
        my SetStatus "Exported image to $f"
    }
    method CmdExportPcb {} {
        set f [tk_getSaveFile -filetypes {{All *}}]
        if {$f eq ""} return
        set base [file rootname $f]
        if {[catch {::schem::pcb::export $S $base} res]} { my SetStatus "PCB export error: $res" ; return }
        set w [llength [dict get $res warnings]]
        my SetStatus "Exported [dict get $res netlist] + [dict get $res bom]  ($w manufacturability note(s))"
    }

    method CmdQuit {} {
        if {$Dirty} {
            set a [tk_messageBox -type yesnocancel -message "Save changes before quitting?" -icon question]
            if {$a eq "cancel"} return
            if {$a eq "yes"} { my CmdSave }
        }
        destroy $Win
        exit
    }

    method CmdHelp {} {
        my TextDialog "Keys & tools" \
"TOOLS
  Select   click parts to select; drag to move; edit values in the Inspector
  Wire     click a pin, then click another pin
  Probe    after Solve, click a pin to read its node voltage

NAVIGATION
  +  -      zoom in / out          0   zoom to 100%        F   fit board to window
  Ctrl+wheel  zoom toward cursor   middle-drag  pan        wheel  scroll

KEYS
  F5  Solve      R  Rotate      Del  Delete      T  ANSI / IEC symbols
  Ctrl+N / O / S   New / Open / Save

ANALYSIS
  Solve            DC operating point (voltages, currents)
  Transient…       time-domain run with a live oscilloscope plot (AC, RC/RL)
  Design-rule check   anti-spaghetti + electrical checks
  Design review    every real part vs its datasheet ratings (over = red)

OUTPUT
  Export image (SVG)        a drawing of the schematic
  Export PCB (KiCad + BOM)  the files a board house manufactures from
  Compile to Zig            the board as a standalone Zig program (zig run)
  Show netlist              the derived nodes + elements

WORKFLOW
  1. Click or drag a part from the bin onto the board
  2. Wire the pins (Wire tool)
  3. Solve (F5); Probe nodes; or run a Transient
  4. Design review checks real parts against datasheet ratings
  5. Export PCB, or Compile to Zig"
    }
    method CmdAbout {} {
        tk_messageBox -type ok -title "About Schem" -message \
"Schem -- a visual electrical programming language.\n\nThe schematic IS the program.  Build circuits from real parts with\ndatasheet specs and limits, simulate them, review them against ratings,\nand export to KiCad + BOM for manufacture."
    }

}
