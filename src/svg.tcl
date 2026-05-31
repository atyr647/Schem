# lib/svg.tcl --
#
# Render a schematic to SVG -- the same box-and-arrow drawing the ASCII viewer
# produces, but as a scalable vector image in the project's dark "Code panel"
# style.  It reuses the engine's own FlowLayout, so the picture matches the
# canonical layout exactly: explicit -at positions when present, otherwise
# signal-flow columns with parts stacked into rows.
#
# A component is a rounded box labelled NAME:type; a wire is an arrowed line
# from the source box to the destination box.  This is a *view* of the object
# model, never the source -- the .schem schematic remains the program.
#
#   set svg [::schem::svg $s]                  ;# returns SVG text
#   ::schem::svgFile $s out.svg                ;# writes it

namespace eval ::schem::render {
    # palette -- the dark theme from the editor's Code panel.
    variable PAL
    array set PAL {
        bg     #1c1c1c   panel  #242424   stroke #9a9a9a   text   #d4d4d4
        dim    #8a8a8a   accent #6a9a6a   grid   #2a2a2a    wire   #9a9a9a
    }
    # box / cell geometry (px)
    variable BW 150  BH 64   COLW 230  ROWH 130   MARGIN 48  HEADER 56
}

# svg -- the SVG document for schematic $s.  opts: -title STR.
proc ::schem::svg {s args} {
    variable render::PAL ; variable render::BW ; variable render::BH
    variable render::COLW ; variable render::ROWH ; variable render::MARGIN
    variable render::HEADER
    set title [$s name]
    foreach {k v} $args { if {$k eq "-title"} { set title $v } }

    set cells [$s FlowLayout]
    # bounds
    set maxc 0 ; set maxr 0
    dict for {c rc} $cells {
        lassign $rc col row
        if {$col > $maxc} { set maxc $col } ; if {$row > $maxr} { set maxr $row }
    }
    set W [expr {2*$MARGIN + ($maxc+1)*$COLW}]
    set H [expr {2*$MARGIN + $HEADER + ($maxr+1)*$ROWH}]

    # pixel centre of a component's box
    set cx {{col} { variable ::schem::render::MARGIN ; variable ::schem::render::COLW ; variable ::schem::render::BW
                    expr {$MARGIN + $col*$COLW + $BW/2} }}
    set cyOf {{row} { variable ::schem::render::MARGIN ; variable ::schem::render::HEADER
                      variable ::schem::render::ROWH ; variable ::schem::render::BH
                      expr {$MARGIN + $HEADER + $row*$ROWH + $BH/2} }}

    set out {}
    lappend out "<?xml version='1.0' encoding='UTF-8'?>"
    lappend out "<svg xmlns='http://www.w3.org/2000/svg' width='$W' height='$H' viewBox='0 0 $W $H' font-family='DejaVu Sans Mono, monospace'>"
    # rounded backdrop panel
    lappend out "<rect x='0' y='0' width='$W' height='$H' rx='22' fill='$PAL(bg)'/>"
    lappend out "<rect x='10' y='10' width='[expr {$W-20}]' height='[expr {$H-20}]' rx='16' fill='$PAL(panel)'/>"
    # header bar: a title + the check / expand glyphs from the editor chrome
    lappend out "<text x='34' y='44' fill='$PAL(dim)' font-size='22'>$title</text>"
    set gx [expr {$W-92}]
    lappend out "<path d='M [expr {$gx}] 32 l 8 9 l 14 -16' stroke='$PAL(dim)' stroke-width='2.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/>"
    lappend out "<path d='M [expr {$gx+40}] 26 h 14 v 14 M [expr {$gx+54}] 26 l -20 20' stroke='$PAL(dim)' stroke-width='2.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/>"
    lappend out "<line x1='22' y1='$HEADER' x2='[expr {$W-22}]' y2='$HEADER' stroke='$PAL(grid)' stroke-width='1.5'/>"

    # arrowhead marker
    lappend out "<defs><marker id='arrow' markerWidth='10' markerHeight='10' refX='8' refY='3' orient='auto' markerUnits='userSpaceOnUse'><path d='M0,0 L8,3 L0,6 Z' fill='$PAL(wire)'/></marker></defs>"

    # ---- wires first (so boxes sit on top) ----
    foreach co [$s conns] {
        lassign $co a b
        set ca [lindex [split $a .] 0] ; set cb [lindex [split $b .] 0]
        if {$ca eq $cb || ![dict exists $cells $ca] || ![dict exists $cells $cb]} continue
        lassign [dict get $cells $ca] acol arow
        lassign [dict get $cells $cb] bcol brow
        set x1 [apply $cx $acol] ; set y1 [apply $cyOf $arow]
        set x2 [apply $cx $bcol] ; set y2 [apply $cyOf $brow]
        # route: straight when aligned, else an L (horizontal then vertical),
        # entering the destination box edge so the arrowhead sits on the border.
        lappend out [::schem::render::Wire $x1 $y1 $x2 $y2 $acol $arow $bcol $brow]
    }

    # ---- component boxes ----
    dict for {c rc} $cells {
        lassign $rc col row
        set x [expr {$MARGIN + $col*$COLW}]
        set y [expr {$MARGIN + $HEADER + $row*$ROWH}]
        set type [$s typeof $c]
        lappend out "<rect x='$x' y='$y' width='$BW' height='$BH' rx='6' fill='$PAL(panel)' stroke='$PAL(stroke)' stroke-width='2'/>"
        set tx [expr {$x + 14}] ; set ty [expr {$y + $BH/2 + 7}]
        lappend out "<text x='$tx' y='$ty' font-size='20'><tspan fill='$PAL(text)'>$c</tspan><tspan fill='$PAL(dim)'>:$type</tspan></text>"
    }

    lappend out "</svg>"
    return [join $out \n]
}

# Wire -- an SVG path between two box centres, drawn to land on the
# destination box edge with an arrowhead.  Straight if same row/col, else an L.
proc ::schem::render::Wire {x1 y1 x2 y2 acol arow bcol brow} {
    variable BW ; variable BH ; variable wire
    variable PAL
    set col $PAL(wire)
    if {$arow == $brow} {
        # horizontal: exit right edge of A, enter left edge of B
        set sx [expr {$x1 + $BW/2}] ; set ex [expr {$x2 - $BW/2}]
        if {$bcol < $acol} { set sx [expr {$x1 - $BW/2}] ; set ex [expr {$x2 + $BW/2}] }
        return "<line x1='$sx' y1='$y1' x2='$ex' y2='$y2' stroke='$col' stroke-width='2' marker-end='url(#arrow)'/>"
    } elseif {$acol == $bcol} {
        # vertical: exit bottom of A, enter top of B
        set sy [expr {$y1 + $BH/2}] ; set ey [expr {$y2 - $BH/2}]
        if {$brow < $arow} { set sy [expr {$y1 - $BH/2}] ; set ey [expr {$y2 + $BH/2}] }
        return "<line x1='$x1' y1='$sy' x2='$x2' y2='$ey' stroke='$col' stroke-width='2' marker-end='url(#arrow)'/>"
    }
    # L-route: horizontal out of A to B's column, then vertical into B's top/bottom.
    set sx [expr {$x1 + $BW/2}] ; if {$bcol < $acol} { set sx [expr {$x1 - $BW/2}] }
    set ey [expr {$y2 - $BH/2}] ; if {$brow < $arow} { set ey [expr {$y2 + $BH/2}] }
    return "<path d='M $sx $y1 H $x2 V $ey' stroke='$col' stroke-width='2' fill='none' marker-end='url(#arrow)'/>"
}

# ----------------------------------------------------------------------
#  Grouped view -- collapse a bundle (parts named NAME#0..NAME#k) into one
#  ribbon box "NAME[width]:type", and draw one fat coupling between two
#  bundles when any of their lanes are wired together.  This is how an
#  engineer draws a bus: a ribbon, not 26 separate conductors.  It makes the
#  big machines (the bombe, a register file) legible.
# ----------------------------------------------------------------------

# groupOf -- the bundle name a component belongs to (NAME from NAME#i), or the
# component's own name if it is not part of a bundle.  (Kept for compatibility;
# the zoom module generalises this to the whole scale ladder.)
proc ::schem::render::groupOf {name} {
    return [::schem::zoom::key $name 3]
}

# svgGrouped -- the SVG for a semantic-zoom view of $s at a given level.  The
# level (grid 0 .. component 4) decides how much of each component's hierarchy
# is resolved before collapsing; level 3 (bundle) is the old "grouped" view.
proc ::schem::svgGrouped {s args} {
    variable render::PAL ; variable render::BW ; variable render::BH
    variable render::COLW ; variable render::ROWH ; variable render::MARGIN
    variable render::HEADER
    set title [$s name] ; set level 3 ; set perRow 6
    foreach {k v} $args {
        switch -- $k {
            -title { set title $v }
            -level { set level [::schem::zoom::clamp $v] }
            -cols  { set perRow $v }
        }
    }

    # Collapse to groups + inter-group edges at this zoom level.
    lassign [::schem::zoom::groups $s $level] groups members gtype
    set gedges [dict create]
    foreach pair [::schem::zoom::edges $s $level] { dict set gedges $pair 1 }

    # Grid layout over the groups.  A bus machine is a mesh (every cable wires
    # to many others), so a longest-path layout degenerates into one enormous
    # row; instead we wrap the groups into a fixed-width grid -- legible, and
    # honest about the fact that these bundles form a fabric, not a pipeline.
    set cells [dict create] ; set maxc 0 ; set maxr 0 ; set i 0
    foreach g $groups {
        set col [expr {$i % $perRow}] ; set row [expr {$i / $perRow}]
        dict set cells $g [list $col $row]
        if {$col > $maxc} { set maxc $col } ; if {$row > $maxr} { set maxr $row }
        incr i
    }

    set W [expr {2*$MARGIN + ($maxc+1)*$COLW}]
    set H [expr {2*$MARGIN + $HEADER + ($maxr+1)*$ROWH}]
    set cx {{col} { variable ::schem::render::MARGIN ; variable ::schem::render::COLW ; variable ::schem::render::BW
                    expr {$MARGIN + $col*$COLW + $BW/2} }}
    set cyOf {{row} { variable ::schem::render::MARGIN ; variable ::schem::render::HEADER
                      variable ::schem::render::ROWH ; variable ::schem::render::BH
                      expr {$MARGIN + $HEADER + $row*$ROWH + $BH/2} }}

    set out {}
    lappend out "<?xml version='1.0' encoding='UTF-8'?>"
    lappend out "<svg xmlns='http://www.w3.org/2000/svg' width='$W' height='$H' viewBox='0 0 $W $H' font-family='DejaVu Sans Mono, monospace'>"
    lappend out "<rect x='0' y='0' width='$W' height='$H' rx='22' fill='$PAL(bg)'/>"
    lappend out "<rect x='10' y='10' width='[expr {$W-20}]' height='[expr {$H-20}]' rx='16' fill='$PAL(panel)'/>"
    lappend out "<text x='34' y='44' fill='$PAL(dim)' font-size='22'>$title</text>"
    set gx [expr {$W-92}]
    lappend out "<path d='M [expr {$gx}] 32 l 8 9 l 14 -16' stroke='$PAL(dim)' stroke-width='2.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/>"
    lappend out "<path d='M [expr {$gx+40}] 26 h 14 v 14 M [expr {$gx+54}] 26 l -20 20' stroke='$PAL(dim)' stroke-width='2.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/>"
    lappend out "<line x1='22' y1='$HEADER' x2='[expr {$W-22}]' y2='$HEADER' stroke='$PAL(grid)' stroke-width='1.5'/>"
    lappend out "<defs><marker id='arrow' markerWidth='10' markerHeight='10' refX='8' refY='3' orient='auto' markerUnits='userSpaceOnUse'><path d='M0,0 L8,3 L0,6 Z' fill='$PAL(wire)'/></marker></defs>"

    # Mesh wiring: a ribbon between bundle boxes, drawn box-edge to box-edge as
    # a gently curved connector so the fabric is readable.
    dict for {e _} $gedges {
        lassign $e ga gb
        if {![dict exists $cells $ga] || ![dict exists $cells $gb]} continue
        lassign [dict get $cells $ga] acol arow
        lassign [dict get $cells $gb] bcol brow
        set x1 [apply $cx $acol] ; set y1 [apply $cyOf $arow]
        set x2 [apply $cx $bcol] ; set y2 [apply $cyOf $brow]
        set wlane [expr {([llength [dict get $members $ga]]>1 || [llength [dict get $members $gb]]>1) ? 4 : 1.5}]
        set my [expr {($y1+$y2)/2}]
        lappend out "<path d='M $x1 $y1 C $x1 $my $x2 $my $x2 $y2' stroke='$PAL(wire)' stroke-width='$wlane' fill='none' opacity='0.55'/>"
    }

    dict for {g cellrc} $cells {
        lassign $cellrc col row
        set x [expr {$MARGIN + $col*$COLW}]
        set y [expr {$MARGIN + $HEADER + $row*$ROWH}]
        set mem [dict get $members $g]
        set n [llength $mem]
        set type [dict get $gtype $g]
        set base [lindex [split $g /] end]
        set label [expr {$n > 1 ? "$base\[$n\]" : $base}]
        # collapsed groups (more than one member) get a doubled edge to read as
        # a ribbon/cable rather than a single component.
        lappend out "<rect x='$x' y='$y' width='$BW' height='$BH' rx='6' fill='$PAL(panel)' stroke='$PAL(stroke)' stroke-width='2'/>"
        if {$n > 1} {
            lappend out "<rect x='[expr {$x+5}]' y='[expr {$y+5}]' width='[expr {$BW-10}]' height='[expr {$BH-10}]' rx='4' fill='none' stroke='$PAL(dim)' stroke-width='1'/>"
        }
        set tx [expr {$x + 14}] ; set ty [expr {$y + $BH/2 + 7}]
        lappend out "<text x='$tx' y='$ty' font-size='18'><tspan fill='$PAL(text)'>$label</tspan><tspan fill='$PAL(dim)'>:$type</tspan></text>"
    }
    lappend out "</svg>"
    return [join $out \n]
}

# svgFile -- write the SVG to a file; returns the byte count.
#   -grouped 1     bundle-level (zoom level 3) view
#   -level N        an explicit zoom level (0 grid .. 4 component); when given,
#                   selects the zoom renderer.  Level 4 is the flat view.
# With neither, the flat per-component view is drawn.
proc ::schem::svgFile {s path args} {
    set grouped 0 ; set level "" ; set pass {}
    foreach {k v} $args {
        switch -- $k {
            -grouped { set grouped $v }
            -level   { set level [::schem::zoom::clamp $v] }
            default  { lappend pass $k $v }
        }
    }
    if {$level eq ""} { set level [expr {$grouped ? 3 : 4}] }
    if {$level >= 4} {
        set svg [::schem::svg $s {*}$pass]
    } else {
        set svg [::schem::svgGrouped $s -level $level {*}$pass]
    }
    set fh [open $path w] ; puts $fh $svg ; close $fh
    return [string length $svg]
}
