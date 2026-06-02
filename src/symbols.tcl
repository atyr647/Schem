# symbols.tcl --
#
# Schematic symbols for the GUI canvas, drawn the way an electrical engineer
# expects to read them -- proper IEC 60617 and ANSI/IEEE 315 glyphs, not
# generic boxes.  A resistor is a rectangle (IEC) or a zigzag (ANSI); a battery
# is the long/short cell plates; ground is the descending bars.  Every symbol
# exposes its terminals at fixed offsets so wires snap to real pins.
#
# Each drawer:  ::schem::sym::draw <canvas> <type> <x> <y> <opts>
#   opts: -scale N  -standard iec|ansi  -tags {..}  -color C  -label TEXT
#         -value TEXT  -rot 0|90|180|270
# returns a dict:  {w <px> h <px> pins {pinName {dx dy} ...}}
# where pin offsets are relative to (x,y) AFTER rotation, in canvas pixels --
# so the caller can place wire endpoints exactly on the pins.
#
# The drawing is pure Tk canvas items tagged with the caller's tags, so the GUI
# can move/delete/highlight a whole symbol by tag.  This file has no Tk
# dependency at load time (it only calls $canvas ... at draw time), so the
# headless engine can still source it.

namespace eval ::schem::sym {
    variable GRID 20      ;# base pin pitch in pixels at scale 1
    # palette (matches the dark Code-panel theme)
    variable INK   "#d4d4d4"
    variable DIM   "#8a8a8a"
    variable LIVE  "#6a9a6a"
    variable HOT   "#c08a4a"
}

# rot -- rotate an offset {dx dy} by 0/90/180/270 degrees.
proc ::schem::sym::rot {dx dy deg} {
    switch -- $deg {
        90  { return [list [expr {-$dy}] $dx] }
        180 { return [list [expr {-$dx}] [expr {-$dy}]] }
        270 { return [list $dy [expr {-$dx}]] }
        default { return [list $dx $dy] }
    }
}

# P -- helper: absolute canvas point for an offset, rotated and scaled.
proc ::schem::sym::P {x y dx dy s deg} {
    lassign [::schem::sym::rot [expr {$dx*$s}] [expr {$dy*$s}] $deg] rx ry
    return [list [expr {$x+$rx}] [expr {$y+$ry}]]
}

# draw -- dispatch to the per-type drawer.
proc ::schem::sym::draw {c type x y args} {
    set o [dict create -scale 1.0 -standard ansi -tags {} -color "" \
        -label "" -value "" -rot 0]
    dict for {k v} $args { dict set o $k $v }
    if {[dict get $o -color] eq ""} { dict set o -color $::schem::sym::INK }
    set fn ::schem::sym::draw_[string map {{ } _} $type]
    if {[llength [info commands $fn]] == 0} { set fn ::schem::sym::draw_generic }
    return [$fn $c $x $y $o [list type $type]]
}

# ---- small drawing helpers -------------------------------------------------
proc ::schem::sym::line {c x y pts o args} {
    set s [dict get $o -scale] ; set deg [dict get $o -rot]
    set coords {}
    foreach {dx dy} $pts { lappend coords {*}[::schem::sym::P $x $y $dx $dy $s $deg] }
    return [$c create line {*}$coords -fill [dict get $o -color] \
        -width [expr {max(1,round(2*$s))}] -tags [dict get $o -tags] {*}$args]
}
proc ::schem::sym::circle {c x y dx dy r o args} {
    set s [dict get $o -scale]
    lassign [::schem::sym::P $x $y $dx $dy $s [dict get $o -rot]] px py
    set rr [expr {$r*$s}]
    return [$c create oval [expr {$px-$rr}] [expr {$py-$rr}] [expr {$px+$rr}] [expr {$py+$rr}] \
        -outline [dict get $o -color] -width [expr {max(1,round(2*$s))}] \
        -tags [dict get $o -tags] {*}$args]
}

# labels -- the reference designator (top) and value (bottom), like a real
# schematic annotation.  Placed clear of the body.
proc ::schem::sym::labels {c x y o hw hh} {
    set s [dict get $o -scale]
    set lab [dict get $o -label] ; set val [dict get $o -value]
    if {$lab ne ""} {
        $c create text $x [expr {$y-($hh+10)*$s}] -text $lab \
            -fill $::schem::sym::INK -font [list TkFixedFont [expr {round(10*$s)}]] \
            -tags [dict get $o -tags] -anchor s
    }
    if {$val ne ""} {
        $c create text $x [expr {$y+($hh+10)*$s}] -text $val \
            -fill $::schem::sym::DIM -font [list TkFixedFont [expr {round(9*$s)}]] \
            -tags [dict get $o -tags] -anchor n
    }
}

# result -- assemble the {w h pins} dict, rotating pin offsets to match.
proc ::schem::sym::result {o w h pinspec} {
    set s [dict get $o -scale] ; set deg [dict get $o -rot]
    set pins [dict create]
    foreach {pin off} $pinspec {
        lassign $off dx dy
        lassign [::schem::sym::rot [expr {$dx*$s}] [expr {$dy*$s}] $deg] rx ry
        dict set pins $pin [list $rx $ry]
    }
    return [dict create w [expr {$w*$s}] h [expr {$h*$s}] pins $pins]
}

# ===========================================================================
#  The symbols.  Coordinates are in grid units (pin pitch 20px) about (0,0).
# ===========================================================================

# resistor -- IEC rectangle or ANSI zigzag, leads left (a) and right (b).
proc ::schem::sym::draw_resistor {c x y o base} {
    if {[dict get $o -standard] eq "iec"} {
        ::schem::sym::line $c $x $y {-30 0 -18 0} $o
        $c create rectangle \
            [lindex [::schem::sym::P $x $y -18 -7 [dict get $o -scale] [dict get $o -rot]] 0] \
            [lindex [::schem::sym::P $x $y -18 -7 [dict get $o -scale] [dict get $o -rot]] 1] \
            [lindex [::schem::sym::P $x $y 18 7 [dict get $o -scale] [dict get $o -rot]] 0] \
            [lindex [::schem::sym::P $x $y 18 7 [dict get $o -scale] [dict get $o -rot]] 1] \
            -outline [dict get $o -color] -width [expr {max(1,round(2*[dict get $o -scale]))}] \
            -tags [dict get $o -tags]
        ::schem::sym::line $c $x $y {18 0 30 0} $o
    } else {
        ::schem::sym::line $c $x $y \
            {-30 0 -18 0 -15 -7 -9 7 -3 -7 3 7 9 -7 15 7 18 0 30 0} $o
    }
    ::schem::sym::labels $c $x $y $o 30 8
    return [::schem::sym::result $o 60 16 {a {-30 0} b {30 0}}]
}

# capacitor -- two plates (IEC/ANSI share the non-polarised glyph), leads a/b.
proc ::schem::sym::draw_capacitor {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -6 0} $o
    ::schem::sym::line $c $x $y {-6 -12 -6 12} $o
    ::schem::sym::line $c $x $y {6 -12 6 12} $o
    ::schem::sym::line $c $x $y {6 0 30 0} $o
    ::schem::sym::labels $c $x $y $o 30 14
    return [::schem::sym::result $o 60 24 {a {-30 0} b {30 0}}]
}

# inductor -- IEC rectangle-with-fill or ANSI series of arcs (humps).
proc ::schem::sym::draw_inductor {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -18 0} $o
    if {[dict get $o -standard] eq "iec"} {
        ::schem::sym::line $c $x $y {-18 -5 18 -5 18 5 -18 5 -18 -5} $o
    } else {
        # four bumps drawn as a polyline approximation of arcs
        set pts {-18 0}
        foreach cx {-12 -4 4 12} {
            lappend pts [expr {$cx-3}] -2 $cx -8 [expr {$cx+3}] -2
        }
        lappend pts 18 0
        ::schem::sym::line $c $x $y $pts $o -smooth 1
    }
    ::schem::sym::line $c $x $y {18 0 30 0} $o
    ::schem::sym::labels $c $x $y $o 30 10
    return [::schem::sym::result $o 60 16 {a {-30 0} b {30 0}}]
}

# battery -- alternating long (+) and short (-) cell plates; pos left, neg right.
proc ::schem::sym::draw_battery {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -10 0} $o
    ::schem::sym::line $c $x $y {-10 -12 -10 12} $o    ;# long plate (+)
    ::schem::sym::line $c $x $y {-2 -6 -2 6} $o        ;# short plate (-)
    ::schem::sym::line $c $x $y {6 -12 6 12} $o        ;# long plate
    ::schem::sym::line $c $x $y {14 -6 14 6} $o        ;# short plate
    ::schem::sym::line $c $x $y {14 0 30 0} $o
    # + marker
    $c create text [lindex [::schem::sym::P $x $y -16 -14 [dict get $o -scale] [dict get $o -rot]] 0] \
        [lindex [::schem::sym::P $x $y -16 -14 [dict get $o -scale] [dict get $o -rot]] 1] \
        -text "+" -fill [dict get $o -color] -font [list TkFixedFont [expr {round(10*[dict get $o -scale])}]] \
        -tags [dict get $o -tags]
    ::schem::sym::labels $c $x $y $o 30 14
    return [::schem::sym::result $o 60 24 {pos {-30 0} neg {30 0}}]
}

# ground -- the three descending bars on a stem; single terminal t at top.
proc ::schem::sym::draw_ground {c x y o base} {
    ::schem::sym::line $c $x $y {0 -20 0 0} $o
    ::schem::sym::line $c $x $y {-12 0 12 0} $o
    ::schem::sym::line $c $x $y {-8 6 8 6} $o
    ::schem::sym::line $c $x $y {-4 12 4 12} $o
    return [::schem::sym::result $o 24 32 {t {0 -20}}]
}

# switch -- a hinged blade, open; terminals a (left) and b (right).
proc ::schem::sym::draw_switch {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -12 0} $o
    ::schem::sym::circle $c $x $y -12 0 2 $o -fill [dict get $o -color]
    ::schem::sym::line $c $x $y {-12 0 10 -12} $o    ;# open blade
    ::schem::sym::circle $c $x $y 12 0 2 $o -fill [dict get $o -color]
    ::schem::sym::line $c $x $y {12 0 30 0} $o
    ::schem::sym::labels $c $x $y $o 30 14
    return [::schem::sym::result $o 60 24 {a {-30 0} b {30 0}}]
}

# button -- a pushbutton: plunger over a gap; terminals a/b.
proc ::schem::sym::draw_button {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -10 0} $o
    ::schem::sym::line $c $x $y {10 0 30 0} $o
    ::schem::sym::line $c $x $y {-10 -2 10 -2} $o     ;# contact bar
    ::schem::sym::line $c $x $y {0 -2 0 -12} $o       ;# plunger stem
    ::schem::sym::line $c $x $y {-8 -12 8 -12} $o     ;# plunger cap
    ::schem::sym::labels $c $x $y $o 30 14
    return [::schem::sym::result $o 60 24 {a {-30 0} b {30 0}}]
}

# diode -- triangle + bar; anode a (left), cathode k (right).
proc ::schem::sym::draw_diode {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -10 0} $o
    ::schem::sym::line $c $x $y {-10 -10 -10 10 10 0 -10 -10} $o   ;# triangle
    ::schem::sym::line $c $x $y {10 -10 10 10} $o                  ;# cathode bar
    ::schem::sym::line $c $x $y {10 0 30 0} $o
    ::schem::sym::labels $c $x $y $o 30 12
    return [::schem::sym::result $o 60 22 {a {-30 0} k {30 0}}]
}

# lamp -- a circle with an X (indicator/incandescent); terminals a/b.
proc ::schem::sym::draw_lamp {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -12 0} $o
    ::schem::sym::circle $c $x $y 0 0 12 $o
    ::schem::sym::line $c $x $y {-8 -8 8 8} $o
    ::schem::sym::line $c $x $y {-8 8 8 -8} $o
    ::schem::sym::line $c $x $y {12 0 30 0} $o
    ::schem::sym::labels $c $x $y $o 30 14
    return [::schem::sym::result $o 60 24 {a {-30 0} b {30 0}}]
}

# fuse -- IEC rectangle with a line through it; terminals a/b.
proc ::schem::sym::draw_fuse {c x y o base} {
    ::schem::sym::line $c $x $y {-30 0 -16 0} $o
    $c create rectangle \
        {*}[::schem::sym::P $x $y -16 -6 [dict get $o -scale] [dict get $o -rot]] \
        {*}[::schem::sym::P $x $y 16 6 [dict get $o -scale] [dict get $o -rot]] \
        -outline [dict get $o -color] -width [expr {max(1,round(2*[dict get $o -scale]))}] \
        -tags [dict get $o -tags]
    ::schem::sym::line $c $x $y {-16 0 16 0} $o
    ::schem::sym::line $c $x $y {16 0 30 0} $o
    ::schem::sym::labels $c $x $y $o 30 10
    return [::schem::sym::result $o 60 16 {a {-30 0} b {30 0}}]
}

# relay -- a coil box plus an SPDT contact set.  Five terminals:
#   c1,c2 coil ; com,no,nc contacts.  Drawn compact with the coil left, the
#   contact right, and a dashed mechanical-link between them.
proc ::schem::sym::draw_relay {c x y o base} {
    set col [dict get $o -color]
    # coil box
    $c create rectangle \
        {*}[::schem::sym::P $x $y -28 -14 [dict get $o -scale] [dict get $o -rot]] \
        {*}[::schem::sym::P $x $y -8 14 [dict get $o -scale] [dict get $o -rot]] \
        -outline $col -width [expr {max(1,round(2*[dict get $o -scale]))}] -tags [dict get $o -tags]
    ::schem::sym::line $c $x $y {-28 -8 -40 -8} $o    ;# c1
    ::schem::sym::line $c $x $y {-28 8 -40 8} $o       ;# c2
    # contact: common pole with NO/NC
    ::schem::sym::line $c $x $y {28 -12 40 -12} $o     ;# no
    ::schem::sym::line $c $x $y {28 12 40 12} $o        ;# nc
    ::schem::sym::line $c $x $y {12 0 -0 0} $o          ;# com lead in
    ::schem::sym::line $c $x $y {12 0 40 0} $o          ;# com out (right)
    ::schem::sym::circle $c $x $y 12 0 2 $o -fill $col
    ::schem::sym::line $c $x $y {12 0 27 -11} $o        ;# blade to NO-ish
    ::schem::sym::circle $c $x $y 28 -12 2 $o -fill $col
    ::schem::sym::circle $c $x $y 28 12 2 $o -fill $col
    # mechanical link (dashed)
    $c create line \
        {*}[::schem::sym::P $x $y -8 0 [dict get $o -scale] [dict get $o -rot]] \
        {*}[::schem::sym::P $x $y 12 0 [dict get $o -scale] [dict get $o -rot]] \
        -fill $::schem::sym::DIM -dash {2 2} -tags [dict get $o -tags]
    ::schem::sym::labels $c $x $y $o 40 18
    return [::schem::sym::result $o 80 32 \
        {c1 {-40 -8} c2 {-40 8} com {40 0} no {40 -12} nc {40 12}}]
}

# generic -- fallback box with the type name; pins along the left/right by
# terminal list passed in base (filled by the GUI from the engine META).
proc ::schem::sym::draw_generic {c x y o base} {
    set col [dict get $o -color]
    $c create rectangle \
        {*}[::schem::sym::P $x $y -28 -16 [dict get $o -scale] [dict get $o -rot]] \
        {*}[::schem::sym::P $x $y 28 16 [dict get $o -scale] [dict get $o -rot]] \
        -outline $col -width [expr {max(1,round(2*[dict get $o -scale]))}] -tags [dict get $o -tags]
    $c create text $x $y -text [dict get $base type] -fill $col \
        -font [list TkFixedFont [expr {round(9*[dict get $o -scale])}]] -tags [dict get $o -tags]
    ::schem::sym::labels $c $x $y $o 28 20
    return [::schem::sym::result $o 56 32 {a {-28 0} b {28 0}}]
}
