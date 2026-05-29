# render.tcl --
#
# The viewer.  A .schem file is a serialized schematic object model; when
# Schem "opens" it, the viewer draws that object model visually -- boxes
# (components) joined by couplings (wires) with direction arrows, the way
# the schematic appears on the workbench:
#
#     ┌─────────┐      ┌─────────┐
#     │ switch  │─────▶│ relay   │
#     └─────────┘      └────┬────┘
#                           ▼
#                      ┌─────────┐
#                      │ breaker │
#                      └─────────┘
#
# This is a *rendering* of the schematic object, not a format and not the
# source.  There is no raw text view: the viewer never lists entities as
# text, it draws them.  The box characters are just the terminal's medium,
# exactly as a GUI editor would draw the same object with pixels.
#
# (The schematic is never SVG, JSON or ASCII.  Those are not the language.)

oo::define ::schem::Schematic {

    # FlowLayout -- assign every component a (column,row) cell from the
    # coupling flow: columns follow signal direction (longest path from a
    # source), rows stack components that share a column.  Cycles (feedback)
    # are capped so the layout always terminates.
    method FlowLayout {} {
        set comps [my components]

        # Honour explicit placement from the object model when every
        # component carries a position; the editor's layout wins over
        # auto-flow.  Positions are mapped to discrete (column,row) cells.
        set haveAll [expr {[llength $comps] > 0}]
        foreach c $comps {
            if {[dict get [my attrs $c] pos] eq {}} { set haveAll 0 ; break }
        }
        if {$haveAll} {
            set xs {} ; set ys {}
            foreach c $comps {
                lassign [dict get [my attrs $c] pos] x y
                lappend xs $x ; lappend ys $y
            }
            set xs [lsort -real -unique $xs] ; set ys [lsort -real -unique $ys]
            set colOf [dict create] ; set i 0 ; foreach x $xs { dict set colOf $x $i ; incr i }
            set rowOf [dict create] ; set i 0 ; foreach y $ys { dict set rowOf $y $i ; incr i }
            set cells [dict create]
            foreach c $comps {
                lassign [dict get [my attrs $c] pos] x y
                dict set cells $c [list [dict get $colOf $x] [dict get $rowOf $y]]
            }
            return $cells
        }

        set edges {}
        foreach co [my conns] {
            lassign $co a b
            set ca [lindex [split $a .] 0]
            set cb [lindex [split $b .] 0]
            if {$ca ne $cb} { lappend edges [list $ca $cb] }
        }
        array set depth {}
        foreach c $comps { set depth($c) 0 }
        set n [llength $comps]
        for {set it 0} {$it < $n} {incr it} {
            foreach e $edges {
                lassign $e f t
                if {$depth($t) < $depth($f) + 1} { set depth($t) [expr {$depth($f)+1}] }
            }
        }
        array set rc {}
        set cells [dict create]
        foreach c $comps {
            set d $depth($c)
            if {![info exists rc($d)]} { set rc($d) 0 }
            dict set cells $c [list $d $rc($d)]
            incr rc($d)
        }
        return $cells
    }

    # view -- draw the schematic object model.
    method view {} {
        set comps [my components]
        if {![llength $comps]} { return "(empty schematic \"$Name\")" }

        # Glyphs (built from code points so the source stays pure ASCII and
        # is independent of the interpreter's system encoding).
        set TL [format %c 0x250C] ; set TR [format %c 0x2510]
        set BL [format %c 0x2514] ; set BR [format %c 0x2518]
        set HZ [format %c 0x2500] ; set VT [format %c 0x2502]
        set AR [format %c 0x25B6] ; set AU [format %c 0x25B2] ; set AD [format %c 0x25BC]
        # mask -> line glyph.  Bits: N=1 S=2 E=4 W=8.  Built from code
        # points so the source has no multibyte literals.
        array set G {}
        set G(1)  $VT ; set G(2)  $VT ; set G(3)  $VT
        set G(4)  $HZ ; set G(8)  $HZ ; set G(12) $HZ
        set G(5)  $BL ; set G(9)  $BR ; set G(6)  $TL ; set G(10) $TR
        set G(7)  [format %c 0x251C] ; set G(11) [format %c 0x2524]
        set G(13) [format %c 0x2534] ; set G(14) [format %c 0x252C]
        set G(15) [format %c 0x253C]

        set cells [my FlowLayout]
        set BW 13 ; set BH 3 ; set CG 7 ; set RG 2   ;# box w/h, col/row gaps

        # Box origin (top-left) per component, and canvas extent.
        set maxc 0 ; set maxr 0
        dict for {c rc} $cells {
            lassign $rc col row
            if {$col > $maxc} { set maxc $col }
            if {$row > $maxr} { set maxr $row }
        }
        set bx [dict create] ; set by [dict create]
        dict for {c rc} $cells {
            lassign $rc col row
            dict set bx $c [expr {$col * ($BW + $CG)}]
            dict set by $c [expr {$row * ($BH + $RG)}]
        }
        set W [expr {($maxc + 1) * ($BW + $CG)}]
        set H [expr {($maxr + 1) * ($BH + $RG) + 3}]   ;# +3: bottom wire channel
        set chan [expr {$H - 2}]

        # overlay = fixed chars (boxes, labels, arrows); wm = wire bitmask.
        array set ov {} ; array set wm {}

        # --- draw the component boxes ---
        dict for {c xy} $bx {
            set x0 [dict get $bx $c] ; set y0 [dict get $by $c]
            set type [my typeof $c]
            set inner [expr {$BW - 2}]
            set name [string range "$c:$type" 0 [expr {$inner-1}]]
            set y1 [expr {$y0+1}] ; set y2 [expr {$y0+2}]
            for {set i 0} {$i < $BW} {incr i} {
                set kx [expr {$x0+$i}]
                set ov($kx,$y0) [expr {$i==0?$TL:($i==$BW-1?$TR:$HZ)}]
                set ov($kx,$y2) [expr {$i==0?$BL:($i==$BW-1?$BR:$HZ)}]
            }
            set ov($x0,$y1) $VT
            set ov([expr {$x0+$BW-1}],$y1) $VT
            set lbl [format " %-*s" [expr {$BW-2}] $name]
            for {set i 1} {$i < $BW-1} {incr i} {
                set kx [expr {$x0+$i}]
                set ov($kx,$y1) [string index $lbl $i]
            }
        }
        # store box rects for occupancy tests
        set occupied [dict create]
        dict for {c xy} $bx {
            set x0 [dict get $bx $c] ; set y0 [dict get $by $c]
            for {set yy $y0} {$yy < $y0+$BH} {incr yy} {
                for {set xx $x0} {$xx < $x0+$BW} {incr xx} { dict set occupied $xx,$yy 1 }
            }
        }

        # --- route the couplings as wires ---
        foreach co [my conns] {
            lassign $co a b awg hn
            set ca [lindex [split $a .] 0] ; set cb [lindex [split $b .] 0]
            if {$ca eq $cb || ![dict exists $bx $ca] || ![dict exists $bx $cb]} continue
            lassign [dict get $cells $ca] cola rowa
            lassign [dict get $cells $cb] colb rowb
            set xa [dict get $bx $ca] ; set ya [dict get $by $ca]
            set xb [dict get $bx $cb] ; set yb [dict get $by $cb]

            if {$colb > $cola} {
                # forward: out the right of A, into the left of B.
                set sx [expr {$xa + $BW}]     ; set sy [expr {$ya + 1}]
                set ex [expr {$xb - 1}]        ; set ey [expr {$yb + 1}]
                set mx [expr {($sx + $ex) / 2}]
                set path [my RoutePath [list $sx $sy $mx $sy $mx $ey $ex $ey]]
                set arrowAt [list $ex $ey] ; set arrowCh $AR
            } elseif {$colb == $cola && $rowb > $rowa} {
                # straight down: out the bottom of A, into the top of B.
                set cx [expr {$xa + $BW/2}]
                set path [my RoutePath [list $cx [expr {$ya+$BH}] $cx [expr {$yb-1}]]]
                set arrowAt [list $cx [expr {$yb-1}]] ; set arrowCh $AD
            } elseif {$colb == $cola && $rowb < $rowa} {
                # straight up: out the top of A, into the bottom of B.
                set cx [expr {$xa + $BW/2}]
                set path [my RoutePath [list $cx [expr {$ya-1}] $cx [expr {$yb+$BH}]]]
                set arrowAt [list $cx [expr {$yb+$BH}]] ; set arrowCh $AU
            } else {
                # backward / same column: route through the bottom channel.
                set sx [expr {$xa + $BW/2}]   ; set sy [expr {$ya + $BH}]
                set ex [expr {$xb + $BW/2}]   ; set ey [expr {$yb + $BH}]
                set path [my RoutePath [list $sx $sy $sx $chan $ex $chan $ex $ey]]
                set arrowAt [list $ex $ey] ; set arrowCh $AU
            }

            # lay the path into the wire bitmask (skipping box cells)
            set m [llength $path]
            for {set i 0} {$i < $m-1} {incr i} {
                lassign [lindex $path $i] x1 y1
                lassign [lindex $path [expr {$i+1}]] x2 y2
                if {$x2 > $x1} { my Wbit wm occupied $x1 $y1 4 ; my Wbit wm occupied $x2 $y2 8 } \
                elseif {$x2 < $x1} { my Wbit wm occupied $x1 $y1 8 ; my Wbit wm occupied $x2 $y2 4 } \
                elseif {$y2 > $y1} { my Wbit wm occupied $x1 $y1 2 ; my Wbit wm occupied $x2 $y2 1 } \
                elseif {$y2 < $y1} { my Wbit wm occupied $x1 $y1 1 ; my Wbit wm occupied $x2 $y2 2 }
            }
            lassign $arrowAt ax ay
            if {![dict exists $occupied $ax,$ay]} { set ov($ax,$ay) $arrowCh }
        }

        # --- compose canvas ---
        set out {}
        lappend out "Schematic: $Name"
        lappend out ""
        for {set y 0} {$y < $H} {incr y} {
            set line ""
            for {set x 0} {$x < $W} {incr x} {
                if {[info exists ov($x,$y)]} {
                    append line $ov($x,$y)
                } elseif {[info exists wm($x,$y)] && $wm($x,$y) != 0} {
                    append line $G($wm($x,$y))
                } else {
                    append line " "
                }
            }
            set t [string trimright $line]
            if {$t ne "" || [llength $out] < $H} { lappend out $t }
        }
        return [string trimright [join $out \n] \n]
    }

    # Wbit -- OR a direction bit into the wire bitmask at (x,y), unless that
    # cell is inside a component box.
    method Wbit {wmVar occVar x y bit} {
        upvar 1 $wmVar wm $occVar occ
        if {[dict exists $occ $x,$y]} return
        set cur [expr {[info exists wm($x,$y)] ? $wm($x,$y) : 0}]
        set wm($x,$y) [expr {$cur | $bit}]
    }

    # RoutePath -- expand a list of orthogonal waypoints {x y x y ...} into
    # the full ordered list of {x y} cells along the path.
    method RoutePath {wp} {
        set pts {}
        foreach {x y} $wp { lappend pts [list $x $y] }
        set cells {}
        for {set i 0} {$i < [llength $pts]-1} {incr i} {
            lassign [lindex $pts $i] x1 y1
            lassign [lindex $pts [expr {$i+1}]] x2 y2
            if {$x1 == $x2 && $y1 == $y2} continue
            if {$x1 == $x2} {
                set step [expr {$y2 > $y1 ? 1 : -1}]
                for {set y $y1} {$y != $y2} {incr y $step} { lappend cells [list $x1 $y] }
            } else {
                set step [expr {$x2 > $x1 ? 1 : -1}]
                for {set x $x1} {$x != $x2} {incr x $step} { lappend cells [list $x $y1] }
            }
        }
        lappend cells [lindex $pts end]
        return $cells
    }
}
