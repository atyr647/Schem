# gui/inspector.tcl -- the inspector panel: properties, measured values, ratings.
# Extends ::schem::gui::App (defined in gui/app.tcl).

oo::define ::schem::gui::App {
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
        # measured operating point (after a solve): voltage across, current,
        # power -- the numbers an engineer reads off the part.
        if {$Result eq "solved"} { my ShowMeasured }
        if {[dict exists $pl ratings]} { my ShowRatings [dict get $pl ratings] }
    }

    method ShowMeasured {} {
        variable ::schem::gui::T
        set rows {}
        set terms [$S terminals $Sel]
        if {[llength $terms] == 2} {
            if {![catch {expr {[$S probe $Sel.[lindex $terms 0]]-[$S probe $Sel.[lindex $terms 1]]}} dv]} {
                lappend rows V [format "%.4g V" $dv]
            }
        }
        if {![catch {$S current $Sel} i]} { lappend rows I [format "%.4g A" $i] }
        if {![catch {$S power $Sel} p] && $p ne ""} { lappend rows P [format "%.4g W" $p] }
        if {[llength $rows] == 0} return
        my InspSection $Insp.ms "Measured"
        set i 0
        foreach {k v} $rows {
            set row [frame $Insp.m$i -bg $T(surface)]
            pack $row -fill x -anchor w -pady 1
            label $row.k -text $k -bg $T(surface) -fg $T(dim) -width 7 -anchor w -font $::schem::gui::FONTSM
            pack $row.k -side left
            label $row.v -text $v -bg $T(surface) -fg $T(accent) -anchor w -font $::schem::gui::FONTMONO
            pack $row.v -side left
            incr i
        }
    }

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

}
