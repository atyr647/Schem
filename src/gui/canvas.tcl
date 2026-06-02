# gui/canvas.tcl -- the schematic canvas: grid, symbols, wires, zoom, placement, interaction.
# Extends ::schem::gui::App (defined in gui/app.tcl).

oo::define ::schem::gui::App {
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
        bind $Canvas <Double-Button-1> [my callback OnDoubleClick %x %y]
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

    method ZoomIn  {} { my SetZoom [expr {$Zoom*1.25}] }

    method ZoomOut {} { my SetZoom [expr {$Zoom/1.25}] }

    method ZoomReset {} { my SetZoom 1.0 }

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

    method WheelZoom {dir x y} {
        set wx [expr {$x/$Zoom}] ; set wy [expr {$y/$Zoom}]
        my SetZoom [expr {$dir > 0 ? $Zoom*1.15 : $Zoom/1.15}]
    }

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

    method DrawComponent {name} {
        variable ::schem::gui::T
        set pl [dict get $Placed $name]
        set type [dict get $pl type]
        set x [expr {[dict get $pl x]*$Zoom}] ; set y [expr {[dict get $pl y]*$Zoom}]
        set rot [dict get $pl rot]
        set partid [dict get $pl partid]
        set val [my ValueText $name]
        set color [my ComponentColor $name]
        set state [expr {![catch {$S get $name state} st] ? $st : ""}]
        set sym [::schem::sym::draw2 $Canvas $type $x $y -scale [expr {1.2*$Zoom}] -standard $Std \
            -rot $rot -tags [list comp comp_$name] -color $color -label $name -value $val -state $state]
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

    method OnDoubleClick {x y} {
        set hit [my ComponentAt [my SnapW $x] [my SnapW $y]]
        if {$hit eq ""} return
        set t [$S typeof $hit]
        switch -- $t {
            switch  { my ToggleState $hit state open closed }
            button  { my ToggleState $hit state released pressed }
            breaker { catch {$S reset $hit} ; my SetStatus "$hit reset (closed)" }
            default { my SetStatus "double-click a switch, button or breaker to operate it" ; return }
        }
        set Sel $hit ; set Result none
        my Redraw ; my ShowInspector
    }

    method ToggleState {name key a b} {
        set cur [expr {![catch {$S get $name $key} v] ? $v : $a}]
        set new [expr {$cur eq $a ? $b : $a}]
        $S set $name $key $new
        set Dirty 1
        my SetStatus "$name -> $new  (double-click to toggle; Solve to update)"
    }

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
        # near a pin -> node voltage; over a component body -> branch current + power
        set pin [my NearestPin $x $y]
        if {$pin ne ""} {
            if {[catch {$S probe $pin} v]} { my SetStatus "no node at $pin" ; return }
            my SetStatus "$pin = [format %.4g $v] V" "[format %.4g $v] V"
            return
        }
        set comp [my ComponentAt [my SnapW $x] [my SnapW $y]]
        if {$comp eq ""} { my SetStatus "Click a pin (voltage) or a part (current)." ; return }
        set msg "$comp" ; set right ""
        if {![catch {$S current $comp} i]} {
            append msg "  I = [format %.4g $i] A" ; set right "[format %.3g $i] A"
        }
        if {![catch {$S power $comp} p] && $p ne ""} {
            append msg "   P = [format %.4g $p] W"
        }
        my SetStatus $msg $right
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

}
