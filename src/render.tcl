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
#
# The drawing core, ::schem::DrawCanvas, is shared by the read-only viewer
# (`$s view`) and the interactive editor, which adds a cursor and empty
# placement slots.

# Box / grid metrics shared by viewer and editor.
namespace eval ::schem {
    variable BW 13 ; variable BH 3 ; variable CG 7 ; variable RG 2
}

# DrawCanvas -- render a schematic's components and couplings to a list of
# text lines.
#   schem  the schematic command
#   cells  dict component -> {col row}
#   opts   dict, optional:
#            cursor {col row}   highlight this grid cell (double border / slot)
#            showEmpty 1        draw empty grid cells as placement slots
#            extraCols N        extra empty columns beyond the rightmost part
#            extraRows N        extra empty rows beyond the lowest part
proc ::schem::DrawCanvas {schem cells opts} {
    variable BW ; variable BH ; variable CG ; variable RG

    set cursor    [expr {[dict exists $opts cursor] ? [dict get $opts cursor] : {}}]
    set showEmpty [expr {[dict exists $opts showEmpty] ? [dict get $opts showEmpty] : 0}]
    set ecols     [expr {[dict exists $opts extraCols] ? [dict get $opts extraCols] : 0}]
    set erows     [expr {[dict exists $opts extraRows] ? [dict get $opts extraRows] : 0}]

    # Glyphs (code points -> source stays ASCII, encoding-independent).
    set TL [format %c 0x250C] ; set TR [format %c 0x2510]
    set BL [format %c 0x2514] ; set BR [format %c 0x2518]
    set HZ [format %c 0x2500] ; set VT [format %c 0x2502]
    set DTL [format %c 0x2554] ; set DTR [format %c 0x2557]
    set DBL [format %c 0x255A] ; set DBR [format %c 0x255D]
    set DHZ [format %c 0x2550] ; set DVT [format %c 0x2551]
    set AR [format %c 0x25B6] ; set AU [format %c 0x25B2] ; set AD [format %c 0x25BC]
    array set G {}
    set G(1)  $VT ; set G(2)  $VT ; set G(3)  $VT
    set G(4)  $HZ ; set G(8)  $HZ ; set G(12) $HZ
    set G(5)  $BL ; set G(9)  $BR ; set G(6)  $TL ; set G(10) $TR
    set G(7)  [format %c 0x251C] ; set G(11) [format %c 0x2524]
    set G(13) [format %c 0x2534] ; set G(14) [format %c 0x252C]
    set G(15) [format %c 0x253C]

    # Grid extent.
    set maxc 0 ; set maxr 0
    dict for {c rc} $cells {
        lassign $rc col row
        if {$col > $maxc} { set maxc $col }
        if {$row > $maxr} { set maxr $row }
    }
    if {$cursor ne {}} {
        lassign $cursor cc cr
        if {$cc > $maxc} { set maxc $cc }
        if {$cr > $maxr} { set maxr $cr }
    }
    incr maxc $ecols ; incr maxr $erows

    set W [expr {($maxc + 1) * ($BW + $CG)}]
    set H [expr {($maxr + 1) * ($BH + $RG) + 3}]
    set chan [expr {$H - 2}]
    if {$W < 1} { set W 1 } ; if {$H < 1} { set H 1 }

    # Reverse map (col,row) -> component, and box origins.
    set at [dict create] ; set bx [dict create] ; set by [dict create]
    dict for {c rc} $cells {
        lassign $rc col row
        dict set at $col,$row $c
        dict set bx $c [expr {$col * ($BW + $CG)}]
        dict set by $c [expr {$row * ($BH + $RG)}]
    }

    array set ov {} ; array set wm {}
    set occupied [dict create]

    # draw a box at (x0,y0) with a corner/edge glyph set and a label
    set drawBox {{x0 y0 label corners} {
        upvar 1 ov ov BW BW
        lassign $corners tl tr bl br hz vt
        set y1 [expr {$y0+1}] ; set y2 [expr {$y0+2}]
        for {set i 0} {$i < $BW} {incr i} {
            set kx [expr {$x0+$i}]
            set ov($kx,$y0) [expr {$i==0?$tl:($i==$BW-1?$tr:$hz)}]
            set ov($kx,$y2) [expr {$i==0?$bl:($i==$BW-1?$br:$hz)}]
        }
        set ov($x0,$y1) $vt
        set ov([expr {$x0+$BW-1}],$y1) $vt
        set lbl [format " %-*s" [expr {$BW-2}] $label]
        for {set i 1} {$i < $BW-1} {incr i} {
            set ov([expr {$x0+$i}],$y1) [string index $lbl $i]
        }
    }}

    # --- components ---
    dict for {c rc} $cells {
        set x0 [dict get $bx $c] ; set y0 [dict get $by $c]
        set inner [expr {$BW - 2}]
        set type [$schem typeof $c]
        set label [string range "$c:$type" 0 [expr {$inner-1}]]
        set onCursor [expr {$cursor ne {} && $rc eq $cursor}]
        if {$onCursor} {
            apply $drawBox $x0 $y0 $label [list $DTL $DTR $DBL $DBR $DHZ $DVT]
        } else {
            apply $drawBox $x0 $y0 $label [list $TL $TR $BL $BR $HZ $VT]
        }
        for {set yy $y0} {$yy < $y0+$BH} {incr yy} {
            for {set xx $x0} {$xx < $x0+$BW} {incr xx} { dict set occupied $xx,$yy 1 }
        }
    }

    # --- empty placement slots (editor) ---
    if {$showEmpty} {
        for {set row 0} {$row <= $maxr} {incr row} {
            for {set col 0} {$col <= $maxc} {incr col} {
                if {[dict exists $at $col,$row]} continue
                set x0 [expr {$col * ($BW + $CG)}] ; set y0 [expr {$row * ($BH + $RG)}]
                set cx [expr {$x0 + $BW/2}] ; set cy [expr {$y0+1}]
                if {$cursor ne {} && [list $col $row] eq $cursor} {
                    set ov([expr {$cx-1}],$cy) "\[" ; set ov($cx,$cy) "+" ; set ov([expr {$cx+1}],$cy) "\]"
                } else {
                    set ov($cx,$cy) "."
                }
            }
        }
    }

    # --- couplings ---
    set Wbit {{x y bit} {
        upvar 1 wm wm occupied occupied
        if {[dict exists $occupied $x,$y]} return
        set cur [expr {[info exists wm($x,$y)] ? $wm($x,$y) : 0}]
        set wm($x,$y) [expr {$cur | $bit}]
    }}
    set routePath {{wp} {
        set pts {} ; foreach {x y} $wp { lappend pts [list $x $y] }
        set cells {}
        for {set i 0} {$i < [llength $pts]-1} {incr i} {
            lassign [lindex $pts $i] x1 y1
            lassign [lindex $pts [expr {$i+1}]] x2 y2
            if {$x1==$x2 && $y1==$y2} continue
            if {$x1==$x2} {
                set step [expr {$y2>$y1?1:-1}]
                for {set y $y1} {$y!=$y2} {incr y $step} { lappend cells [list $x1 $y] }
            } else {
                set step [expr {$x2>$x1?1:-1}]
                for {set x $x1} {$x!=$x2} {incr x $step} { lappend cells [list $x $y1] }
            }
        }
        lappend cells [lindex $pts end] ; return $cells
    }}

    foreach co [$schem conns] {
        lassign $co a b awg hn
        set ca [lindex [split $a .] 0] ; set cb [lindex [split $b .] 0]
        if {$ca eq $cb || ![dict exists $cells $ca] || ![dict exists $cells $cb]} continue
        lassign [dict get $cells $ca] cola rowa
        lassign [dict get $cells $cb] colb rowb
        set xa [dict get $bx $ca] ; set ya [dict get $by $ca]
        set xb [dict get $bx $cb] ; set yb [dict get $by $cb]
        if {$colb > $cola} {
            set sx [expr {$xa+$BW}] ; set sy [expr {$ya+1}]
            set ex [expr {$xb-1}]   ; set ey [expr {$yb+1}]
            set mx [expr {($sx+$ex)/2}]
            set path [apply $routePath [list $sx $sy $mx $sy $mx $ey $ex $ey]]
            set arrowAt [list $ex $ey] ; set arrowCh $AR
        } elseif {$colb==$cola && $rowb>$rowa} {
            set cx [expr {$xa+$BW/2}]
            set path [apply $routePath [list $cx [expr {$ya+$BH}] $cx [expr {$yb-1}]]]
            set arrowAt [list $cx [expr {$yb-1}]] ; set arrowCh $AD
        } elseif {$colb==$cola && $rowb<$rowa} {
            set cx [expr {$xa+$BW/2}]
            set path [apply $routePath [list $cx [expr {$ya-1}] $cx [expr {$yb+$BH}]]]
            set arrowAt [list $cx [expr {$yb+$BH}]] ; set arrowCh $AU
        } else {
            set sx [expr {$xa+$BW/2}] ; set ex [expr {$xb+$BW/2}]
            set path [apply $routePath [list $sx [expr {$ya+$BH}] $sx $chan $ex $chan $ex [expr {$yb+$BH}]]]
            set arrowAt [list $ex [expr {$yb+$BH}]] ; set arrowCh $AU
        }
        set m [llength $path]
        for {set i 0} {$i < $m-1} {incr i} {
            lassign [lindex $path $i] x1 y1
            lassign [lindex $path [expr {$i+1}]] x2 y2
            if {$x2>$x1} { apply $Wbit $x1 $y1 4 ; apply $Wbit $x2 $y2 8 } \
            elseif {$x2<$x1} { apply $Wbit $x1 $y1 8 ; apply $Wbit $x2 $y2 4 } \
            elseif {$y2>$y1} { apply $Wbit $x1 $y1 2 ; apply $Wbit $x2 $y2 1 } \
            elseif {$y2<$y1} { apply $Wbit $x1 $y1 1 ; apply $Wbit $x2 $y2 2 }
        }
        lassign $arrowAt ax ay
        if {![dict exists $occupied $ax,$ay]} { set ov($ax,$ay) $arrowCh }
    }

    # --- compose ---
    set lines {}
    for {set y 0} {$y < $H} {incr y} {
        set line ""
        for {set x 0} {$x < $W} {incr x} {
            if {[info exists ov($x,$y)]} { append line $ov($x,$y) } \
            elseif {[info exists wm($x,$y)] && $wm($x,$y) != 0} { append line $G($wm($x,$y)) } \
            else { append line " " }
        }
        lappend lines [string trimright $line]
    }
    return $lines
}

oo::define ::schem::Schematic {

    # FlowLayout -- assign every component a (column,row) cell.  Honours
    # explicit positions from the object model when every component carries
    # one; otherwise lays parts out by signal flow (longest path from a
    # source), stacking shared-column parts into rows.  Cycles are capped.
    method FlowLayout {} {
        set comps [my components]
        set haveAll [expr {[llength $comps] > 0}]
        foreach c $comps {
            if {[dict get [my attrs $c] pos] eq {}} { set haveAll 0 ; break }
        }
        if {$haveAll} {
            set xs {} ; set ys {}
            foreach c $comps { lassign [dict get [my attrs $c] pos] x y ; lappend xs $x ; lappend ys $y }
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
            set ca [lindex [split $a .] 0] ; set cb [lindex [split $b .] 0]
            if {$ca ne $cb} { lappend edges [list $ca $cb] }
        }
        array set depth {} ; foreach c $comps { set depth($c) 0 }
        set n [llength $comps]
        for {set it 0} {$it < $n} {incr it} {
            foreach e $edges {
                lassign $e f t
                if {$depth($t) < $depth($f)+1} { set depth($t) [expr {$depth($f)+1}] }
            }
        }
        array set rc {} ; set cells [dict create]
        foreach c $comps {
            set d $depth($c)
            if {![info exists rc($d)]} { set rc($d) 0 }
            dict set cells $c [list $d $rc($d)]
            incr rc($d)
        }
        return $cells
    }
    export FlowLayout

    # view -- draw the schematic object model (read-only).
    method view {} {
        set comps [my components]
        if {![llength $comps]} { return "(empty schematic \"$Name\")" }
        set lines [::schem::DrawCanvas [self] [my FlowLayout] {}]
        return "Schematic: $Name\n\n[string trimright [join $lines \n] \n]"
    }
}
