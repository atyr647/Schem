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
    # theme -- the dark "Code panel" palette, shared with the SVG renderer.
    variable T
    array set T {
        bg      "#1c1c1c"   panel   "#242424"   panel2  "#2a2a2a"
        ink     "#d4d4d4"   dim     "#8a8a8a"   faint   "#5a5a5a"
        line    "#9a9a9a"   grid    "#262626"   gridhi  "#303030"
        accent  "#6a9a6a"   warn    "#c0894a"   bad     "#c05a5a"
        sel     "#6a8ac0"   live    "#7ab87a"   hot     "#c08a4a"
        wire    "#9a9a9a"   probe   "#c0b04a"
    }
    variable FONT       {TkDefaultFont 10}
    variable FONTMONO   {TkFixedFont 10}
    variable FONTH      {TkDefaultFont 11 bold}
    variable _wincount 0
}

# ---------------------------------------------------------------------------
#  App -- one editor window over one schematic.
# ---------------------------------------------------------------------------
oo::class create ::schem::gui::App {
    variable S          ;# the schematic (model)
    variable Win        ;# toplevel
    variable Canvas     ;# the schematic canvas
    variable Parts      ;# parts-bin tree
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
    variable Grid       ;# snap grid in px
    variable PendWire   ;# wire-in-progress: starting terminal or ""
    variable Pending    ;# armed placement: {primitive TYPE} | {part ID} | ""
    variable Result     ;# last solve result flag

    constructor {{schem {}} {parent {}}} {
        if {$schem eq ""} { set S [::schem::new untitled] } else { set S $schem }
        set File "" ; set Dirty 0 ; set Std ansi ; set Tool select
        set Placed [dict create] ; set Wires {} ; set Sel ""
        set Counter [dict create] ; set Grid 20 ; set PendWire "" ; set Result none
        set Pending ""
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
            verdict        { return [expr {[dict exists $Placed [lindex $args 0] verdict] ? [dict get $Placed [lindex $args 0] verdict] : "ok"}] }
            redraw         { my Redraw }
            default        { return -code error "unknown do action: $action" }
        }
    }

    # callback -- a command prefix that invokes a method on THIS object, for
    # -command / bind.  (Tcl 8.7 has a built-in `callback`; we provide our own
    # so the workbench runs on stock 8.6.)  Trailing %-substitutions from bind
    # are appended by Tk after these args.
    method callback {args} { return [list [self] {*}$args] }

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

    method BuildMenu {} {
        variable ::schem::gui::T
        set m [menu $Win.menu -tearoff 0 -bg $T(panel) -fg $T(ink) \
            -activebackground $T(sel) -activeforeground white]
        $Win configure -menu $m
        set fm [menu $m.file -tearoff 0]
        $m add cascade -label File -menu $fm
        $fm add command -label "New"        -accelerator Ctrl+N -command [my callback Cmd new]
        $fm add command -label "Open..."    -accelerator Ctrl+O -command [my callback Cmd open]
        $fm add command -label "Save"       -accelerator Ctrl+S -command [my callback Cmd save]
        $fm add command -label "Save As..."                     -command [my callback Cmd saveas]
        $fm add separator
        $fm add command -label "Export image (SVG)..."          -command [my callback Cmd export_svg]
        $fm add command -label "Export PCB (KiCad + BOM)..."    -command [my callback Cmd export_pcb]
        $fm add separator
        $fm add command -label "Quit"       -accelerator Ctrl+Q -command [my callback Cmd quit]
        set em [menu $m.edit -tearoff 0]
        $m add cascade -label Edit -menu $em
        $em add command -label "Delete selected" -accelerator Del -command [my callback Cmd delete]
        $em add command -label "Rotate selected" -accelerator R   -command [my callback Cmd rotate]
        $em add command -label "Clear board"                      -command [my callback Cmd clear]
        set vm [menu $m.view -tearoff 0]
        $m add cascade -label View -menu $vm
        $vm add command -label "Symbols: ANSI / IEC (toggle)" -accelerator T -command [my callback Cmd togglestd]
        $vm add command -label "Fit to window"                                -command [my callback Cmd fit]
        set sm [menu $m.sim -tearoff 0]
        $m add cascade -label Simulate -menu $sm
        $sm add command -label "Solve (DC operating point)" -accelerator F5 -command [my callback Cmd solve]
        $sm add command -label "Clear results"                              -command [my callback Cmd clearresults]
        set mm [menu $m.man -tearoff 0]
        $m add cascade -label Manufacture -menu $mm
        $mm add command -label "Design review (check ratings)" -command [my callback Cmd review]
        $mm add command -label "Export PCB (KiCad + BOM)..."   -command [my callback Cmd export_pcb]
        set hm [menu $m.help -tearoff 0]
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
    }

    method BuildToolbar {} {
        variable ::schem::gui::T
        set tb [frame $Win.tb -bg $T(panel2)]
        pack $tb -side top -fill x
        foreach {tool label} {select Select wire Wire probe Probe} {
            set b [radiobutton $tb.t$tool -text $label -value $tool \
                -variable [my varname Tool] -indicatoron 0 -width 8 \
                -command [my callback SetTool $tool] \
                -bg $T(panel) -fg $T(ink) -selectcolor $T(sel) \
                -activebackground $T(sel) -relief flat -padx 8 -pady 4]
            pack $b -side left -padx 2 -pady 3
        }
        # separators + quick actions
        label $tb.sep1 -text "  |  " -bg $T(panel2) -fg $T(faint)
        pack $tb.sep1 -side left
        foreach {cmd label} {solve "Solve (F5)" review "Design review" rotate "Rotate (R)" delete "Delete"} {
            set b [button $tb.b$cmd -text $label -command [my callback Cmd $cmd] \
                -bg $T(panel) -fg $T(ink) -activebackground $T(sel) \
                -relief flat -padx 8 -pady 4]
            pack $b -side left -padx 2 -pady 3
        }
        label $tb.std -textvariable [my varname Std] -bg $T(panel2) -fg $T(accent) -width 6
        pack $tb.std -side right -padx 8
        label $tb.stdl -text "symbols:" -bg $T(panel2) -fg $T(dim)
        pack $tb.stdl -side right
    }

    method BuildPartsBin {parent} {
        variable ::schem::gui::T
        set f [frame $parent.bin -bg $T(panel) -width 220]
        pack $f -side left -fill y
        pack propagate $f 0
        label $f.h -text "PARTS BIN" -bg $T(panel) -fg $T(dim) -anchor w \
            -font $::schem::gui::FONTH -padx 10 -pady 6
        pack $f.h -side top -fill x
        # a scrollable tree of catalog categories -> parts
        set tree [frame $f.tree -bg $T(panel)]
        pack $tree -side top -fill both -expand 1
        set Parts [text $tree.t -bg $T(panel) -fg $T(ink) -bd 0 -highlightthickness 0 \
            -cursor hand2 -wrap none -padx 8 -font $::schem::gui::FONTMONO \
            -yscrollcommand [list $tree.sb set]]
        scrollbar $tree.sb -command [list $Parts yview] -bg $T(panel2) -troughcolor $T(panel)
        pack $tree.sb -side right -fill y
        pack $Parts -side left -fill both -expand 1
        my PopulateParts
    }

    method BuildCanvas {parent} {
        variable ::schem::gui::T
        set f [frame $parent.cv -bg $T(bg)]
        pack $f -side left -fill both -expand 1
        set Canvas [canvas $f.c -bg $T(bg) -highlightthickness 0]
        set hsb [scrollbar $f.h -orient horizontal -command [list $Canvas xview] \
            -bg $T(panel2) -troughcolor $T(bg)]
        set vsb [scrollbar $f.v -orient vertical -command [list $Canvas yview] \
            -bg $T(panel2) -troughcolor $T(bg)]
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
    }

    method BuildInspector {parent} {
        variable ::schem::gui::T
        set f [frame $parent.insp -bg $T(panel) -width 280]
        pack $f -side right -fill y
        pack propagate $f 0
        label $f.h -text "INSPECTOR" -bg $T(panel) -fg $T(dim) -anchor w \
            -font $::schem::gui::FONTH -padx 10 -pady 6
        pack $f.h -side top -fill x
        set Insp [frame $f.body -bg $T(panel)]
        pack $Insp -side top -fill both -expand 1 -padx 8
        my ShowInspector
    }

    method BuildStatusBar {} {
        variable ::schem::gui::T
        set sb [frame $Win.sb -bg $T(panel2)]
        pack $sb -side bottom -fill x
        label $sb.l -textvariable [my varname Status](text) -bg $T(panel2) -fg $T(dim) \
            -anchor w -padx 10 -pady 3 -font $::schem::gui::FONT
        pack $sb.l -side left -fill x -expand 1
        label $sb.r -textvariable [my varname Status](right) -bg $T(panel2) -fg $T(accent) \
            -anchor e -padx 10 -font $::schem::gui::FONTMONO
        pack $sb.r -side right
    }

    method ApplyTheme {} {
        variable ::schem::gui::T
        # ttk-free; just ensure option defaults for any future widgets
        option add *background $T(panel)
        option add *foreground $T(ink)
    }

    method SetStatus {msg {right ""}} {
        set Status(text) $msg ; set Status(right) $right
    }

    # ----- parts bin -------------------------------------------------------
    # The catalog an engineer reaches into: primitive building blocks at the
    # top (the raw electrical elements), then the REAL parts grouped by the job
    # they do (rectifier, smoothing, transistor, ...).  Click a part, then click
    # the canvas to place it -- or drag it straight onto the board.
    method PopulateParts {} {
        variable ::schem::gui::T
        $Parts configure -state normal
        $Parts delete 1.0 end
        $Parts tag configure cat -foreground $T(accent) -font {TkDefaultFont 10 bold} \
            -spacing1 8 -spacing3 2
        $Parts tag configure prim -foreground $T(ink) -lmargin1 16 -lmargin2 16
        $Parts tag configure part -foreground $T(ink) -lmargin1 16 -lmargin2 28
        $Parts tag configure spec -foreground $T(dim)

        # primitive elements -- the basic parts, grouped like a part bin
        my BinCategory "BASIC ELEMENTS"
        foreach {type label} {
            battery "Battery / source"  vsource "AC source (~)"  ground "Ground"
            resistor "Resistor"  capacitor "Capacitor"  inductor "Inductor"
            switch "Switch"  button "Pushbutton"  relay "Relay"
            diode "Diode"  bjt "Transistor (BJT)"  mosfet "MOSFET"
            lamp "Lamp"  fuse "Fuse"  junction "Junction / node"
        } {
            my BinPrimitive $type $label
        }

        # real parts, by category
        foreach cat [::schem::parts::categories] {
            my BinCategory [string toupper "$cat parts"]
            foreach id [::schem::parts::byCategory $cat] {
                my BinPart $id
            }
        }
        $Parts configure -state disabled
    }

    method BinCategory {name} {
        $Parts insert end "$name\n" cat
    }
    method BinPrimitive {type label} {
        variable ::schem::gui::T
        set tag "prim_$type"
        $Parts insert end "  $label\n" [list prim $tag]
        $Parts tag bind $tag <Button-1> [my callback PickPrimitive $type]
        $Parts tag bind $tag <Enter> [list $Parts tag configure $tag -background $T(panel2)]
        $Parts tag bind $tag <Leave> [list $Parts tag configure $tag -background $T(panel)]
    }
    method BinPart {id} {
        variable ::schem::gui::T
        set spec [::schem::parts::get $id]
        set tag "part_$id"
        $Parts insert end "  $id" [list part $tag]
        $Parts insert end "  [dict get $spec desc]\n" [list spec $tag]
        $Parts tag bind $tag <Button-1> [my callback PickPart $id]
        $Parts tag bind $tag <Enter> [list $Parts tag configure $tag -background $T(panel2)]
        $Parts tag bind $tag <Leave> [list $Parts tag configure $tag -background $T(panel)]
    }

    # PickPrimitive / PickPart -- arm placement of the chosen part; the next
    # canvas click drops it.
    method PickPrimitive {type} {
        set Pending [list primitive $type]
        my SetStatus "Place '$type' -- click on the schematic." "primitive: $type"
    }
    method PickPart {id} {
        set Pending [list part $id]
        my SetStatus "Place '$id' -- click on the schematic." "part: $id"
    }

    method SetTool {t} { set Tool $t ; set PendWire "" ; my SetStatus "Tool: $t" ; my Redraw }

    # ----- the canvas: grid, symbols, wires, probes ------------------------
    method Redraw {} {
        variable ::schem::gui::T
        if {![winfo exists $Canvas]} return
        $Canvas delete all
        my DrawGrid
        if {[dict size $Placed] == 0} { my DrawWelcome ; return }
        # wires first (under symbols)
        foreach w $Wires { my DrawWire $w }
        # pending wire rubber-band handled in OnHover
        # components
        dict for {name pl} $Placed { my DrawComponent $name }
        # selection halo
        if {$Sel ne "" && [dict exists $Placed $Sel]} { my DrawSelection $Sel }
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

    method DrawGrid {} {
        variable ::schem::gui::T
        lassign [my CanvasSize] W H
        set g $Grid
        for {set x 0} {$x < $W} {incr x $g} {
            set hi [expr {$x % ($g*5) == 0}]
            $Canvas create line $x 0 $x $H -fill [expr {$hi ? $T(gridhi) : $T(grid)}] -tags grid
        }
        for {set y 0} {$y < $H} {incr y $g} {
            set hi [expr {$y % ($g*5) == 0}]
            $Canvas create line 0 $y $W $y -fill [expr {$hi ? $T(gridhi) : $T(grid)}] -tags grid
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
        set x [dict get $pl x] ; set y [dict get $pl y]
        set rot [dict get $pl rot]
        set partid [dict get $pl partid]
        set val [my ValueText $name]
        set color [my ComponentColor $name]
        set sym [::schem::sym::draw $Canvas $type $x $y -scale 1.2 -standard $Std \
            -rot $rot -tags [list comp comp_$name] -color $color -label $name -value $val]
        # pin dots + record absolute positions
        set abspins [dict create]
        dict for {pin off} [dict get $sym pins] {
            lassign $off dx dy
            set px [expr {$x+$dx}] ; set py [expr {$y+$dy}]
            dict set abspins $pin [list $px $py]
            $Canvas create oval [expr {$px-3}] [expr {$py-3}] [expr {$px+3}] [expr {$py+3}] \
                -fill $T(panel) -outline $T(dim) -width 1 -tags [list pin pin_${name}_$pin]
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
        if {$v > 6} { return $T(live) }
        return $T(wire)
    }

    # ----- interaction -----------------------------------------------------
    method OnClick {x y} {
        set x [my Snap $x] ; set y [my Snap $y]
        if {$Pending ne ""} { my PlacePending $x $y ; return }
        switch -- $Tool {
            select { my SelectAt $x $y }
            wire   { my WireClick $x $y }
            probe  { my ProbeAt $x $y }
        }
    }

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

    method ComponentAt {x y} {
        set best "" ; set bestd 1e9
        dict for {name pl} $Placed {
            set dx [expr {$x-[dict get $pl x]}] ; set dy [expr {$y-[dict get $pl y]}]
            set d [expr {$dx*$dx+$dy*$dy}]
            if {$d < $bestd && $d < 2500} { set bestd $d ; set best $name }
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
        # drag the selected component
        if {$Tool ne "select" || $Sel eq "" || $Pending ne ""} return
        set x [my Snap $x] ; set y [my Snap $y]
        dict set Placed $Sel x $x ; dict set Placed $Sel y $y
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
        set hit [my ComponentAt [my Snap $x] [my Snap $y]]
        if {$hit ne ""} { set Sel $hit ; my Redraw ; my ShowInspector }
    }

    # ----- inspector -------------------------------------------------------
    method ShowInspector {} {
        variable ::schem::gui::T
        if {![info exists Insp] || ![winfo exists $Insp]} return
        foreach c [winfo children $Insp] { destroy $c }
        if {$Sel eq "" || ![dict exists $Placed $Sel]} {
            label $Insp.none -text "No selection.\n\nClick a part to inspect\nand edit its values." \
                -bg $T(panel) -fg $T(dim) -justify left -anchor nw
            pack $Insp.none -fill x -anchor nw -pady 8
            my ShowBoardSummary
            return
        }
        set pl [dict get $Placed $Sel]
        set type [dict get $pl type] ; set partid [dict get $pl partid]
        label $Insp.name -text $Sel -bg $T(panel) -fg $T(ink) -font {TkDefaultFont 14 bold} -anchor w
        pack $Insp.name -fill x -anchor w
        label $Insp.type -text $type -bg $T(panel) -fg $T(accent) -anchor w
        pack $Insp.type -fill x -anchor w
        if {$partid ne ""} {
            set spec [::schem::parts::get $partid]
            label $Insp.pid -text "$partid -- [dict get $spec mfr]" -bg $T(panel) -fg $T(dim) \
                -anchor w -wraplength 250 -justify left
            pack $Insp.pid -fill x -anchor w
            label $Insp.pdesc -text [dict get $spec desc] -bg $T(panel) -fg $T(dim) \
                -anchor w -wraplength 250 -justify left
            pack $Insp.pdesc -fill x -anchor w -pady {0 6}
        }
        if {![catch {$S get $Sel} params] && [dict size $params]} {
            label $Insp.ph -text "PARAMETERS" -bg $T(panel) -fg $T(dim) -font {TkDefaultFont 9 bold} -anchor w
            pack $Insp.ph -fill x -anchor w -pady {8 2}
            set i 0
            dict for {k v} $params {
                set row [frame $Insp.p$i -bg $T(panel)]
                pack $row -fill x -anchor w -pady 1
                label $row.k -text $k -bg $T(panel) -fg $T(ink) -width 8 -anchor w
                pack $row.k -side left
                set ev [entry $row.v -bg $T(panel2) -fg $T(ink) -insertbackground $T(ink) -relief flat -width 14]
                $ev insert 0 $v
                pack $ev -side left -fill x -expand 1
                bind $ev <Return>   [my callback SetParam $Sel $k $ev]
                bind $ev <FocusOut> [my callback SetParam $Sel $k $ev]
                incr i
            }
        }
        if {[dict exists $pl ratings]} { my ShowRatings [dict get $pl ratings] }
    }

    method ShowRatings {findings} {
        variable ::schem::gui::T
        label $Insp.rh -text "RATINGS" -bg $T(panel) -fg $T(dim) -font {TkDefaultFont 9 bold} -anchor w
        pack $Insp.rh -fill x -anchor w -pady {10 2}
        set i 0
        foreach r $findings {
            set col [dict get {over #c05a5a marginal #c0894a ok #6a9a6a} [dict get $r verdict]]
            set txt [format "%s  %.3g/%.3g %s  (%.0f%%)" [dict get $r limit] \
                [dict get $r measured] [dict get $r rating] [dict get $r unit] \
                [expr {[dict get $r margin]*100}]]
            label $Insp.r$i -text $txt -bg $T(panel) -fg $col -anchor w -font {TkFixedFont 9}
            pack $Insp.r$i -fill x -anchor w
            incr i
        }
    }

    method ShowBoardSummary {} {
        variable ::schem::gui::T
        label $Insp.sum -text "Board: [dict size $Placed] part(s), [llength $Wires] wire(s)" \
            -bg $T(panel) -fg $T(dim) -anchor w -wraplength 250 -justify left
        pack $Insp.sum -fill x -anchor w -pady {16 0}
        if {$Result eq "solved"} {
            label $Insp.solved -text "Solved.  Use Probe to read nodes." -bg $T(panel) \
                -fg $T(accent) -anchor w -wraplength 250 -justify left
            pack $Insp.solved -fill x -anchor w
        }
        # a couple of real-part placements get a one-line nudge toward the
        # design review -- the workflow an EE expects next.
        if {[dict size $Placed] > 0 && $Result ne "solved"} {
            label $Insp.hint -text "Press F5 to solve, then Manufacture -> Design review to check parts against their ratings." \
                -bg $T(panel) -fg $T(faint) -anchor w -wraplength 250 -justify left
            pack $Insp.hint -fill x -anchor w -pady {8 0}
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
            togglestd  { set Std [expr {$Std eq "ansi" ? "iec" : "ansi"}] ; my Redraw ; my SetStatus "symbols: $Std" }
            fit        { my Redraw }
            solve      { my CmdSolve }
            clearresults { set Result none ; my Redraw ; my SetStatus "results cleared" }
            review     { my CmdReview }
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
        tk_messageBox -type ok -title "Schem -- keys & tools" -message \
"TOOLS\n  Select  - click/drag parts, edit values in the Inspector\n  Wire    - click a pin, then click another pin\n  Probe   - after Solve, click a pin to read its voltage\n\nKEYS\n  F5  Solve      R  Rotate      Del  Delete      T  Toggle ANSI/IEC\n  Ctrl+N/O/S  New / Open / Save\n\nWORKFLOW\n  1. Click a part in the bin, click the canvas to place it\n  2. Wire the pins (Wire tool)\n  3. Solve (F5), Probe nodes\n  4. Design review checks real parts against datasheet ratings\n  5. Export PCB -> KiCad netlist + BOM for the board house"
    }
    method CmdAbout {} {
        tk_messageBox -type ok -title "About Schem" -message \
"Schem -- a visual electrical programming language.\n\nThe schematic IS the program.  Build circuits from real parts with\ndatasheet specs and limits, simulate them, review them against ratings,\nand export to KiCad + BOM for manufacture."
    }

}
