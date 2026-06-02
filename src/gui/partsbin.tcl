# gui/partsbin.tcl -- the parts bin: search, category filter, symbol rows, drag-and-drop.
# Extends ::schem::gui::App (defined in gui/app.tcl).

oo::define ::schem::gui::App {
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

    method BuildCatMenu {m} {
        $m delete 0 end
        $m add command -label "All parts" -command [my callback SetCat all]
        $m add command -label "Basic elements" -command [my callback SetCat basics]
        $m add separator
        foreach c [::schem::parts::categories] {
            $m add command -label [my TitleCase $c] -command [my callback SetCat $c]
        }
    }

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
        ::schem::sym::draw2 $Parts $type $cx $cy -scale 0.42 -standard $Std \
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

    method ShortDesc {d} {
        set i [string first " -- " $d]
        if {$i > 0} { return [string range $d 0 [expr {$i-1}]] }
        return $d
    }

    method PickPrimitive {type} {
        set Pending [list primitive $type]
        my SetStatus "Click the board to place this ${type}." "+ $type"
    }

    method PickPart {id} {
        set Pending [list part $id]
        my SetStatus "Click the board to place ${id}." "+ $id"
    }

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
            ::schem::sym::draw2 $g.c [dict get $Drag type] 40 28 -scale 0.7 \
                -standard $Std -color $T(ink)
        }
        wm geometry $g +[expr {$X+12}]+[expr {$Y+12}]
        raise $g
    }

    method KillDragGhost {} { catch {destroy .dragghost} }

}
