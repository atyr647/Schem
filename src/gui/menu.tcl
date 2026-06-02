# gui/menu.tcl -- menu bar + custom-drawn toolbar.
# Extends ::schem::gui::App (defined in gui/app.tcl).

oo::define ::schem::gui::App {
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
        $sm add command -label "AC frequency sweep…"        -command [my callback Cmd acsweep]
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

}
