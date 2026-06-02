# ksym.tcl --
#
# Render real, standards-compliant schematic symbols on a Tk canvas, parsed
# from KiCad's symbol library (vendored in lib/symbols/standard.kicad_lib).
#
# Why this exists: hand-drawing symbols by eye produced subtly wrong glyphs
# (a diode that looked like an SCR, a mis-placed battery).  KiCad's symbols are
# the peer-reviewed, IEEE-315 / IEC-60617 reference the whole industry uses,
# and they carry exact pin positions/polarity -- so a diode's cathode bar, a
# battery's +/- plates and a transistor's emitter arrow are correct by
# construction, not by my guesswork.
#
# The legacy .lib format is line-records inside DEF..ENDDEF / DRAW..ENDDRAW:
#   P n u c thk x1 y1 ... [fill]     polyline (n points)
#   S x1 y1 x2 y2 u c thk fill       rectangle
#   C x y r u c thk fill             circle
#   A x y r a1 a2 u c thk fill sx sy ex ey   arc (centre,radius,endpoints)
#   X name num x y len dir nsz lsz u c etype  pin
# KiCad Y is up-positive; canvas Y is down-positive, so we negate Y on draw.

package require Tcl 8.6
namespace eval ::schem::ksym {
    variable SYM        ;# schem-type -> {prims {..} pins {name {x y} ..} bbox {..}}
    array set SYM {}
    variable LOADED 0
    # remember where THIS file lives, so the default library path resolves no
    # matter what [info script] is at call time.
    variable DIR [file dirname [file normalize [info script]]]

    # Map a KiCad pin label (within a symbol) to the engine's terminal name for
    # that Schem primitive, so wires land on the right node.  Keyed by
    # "schemtype/kicadpin" or "schemtype/#pinnum".
    variable PINMAP
    array set PINMAP {
        diode/K k    diode/A a
        zener/K k    zener/A a
        schottky/K k schottky/A a
        battery/+ pos  battery/- neg
        vsource/#1 pos vsource/#2 neg
        switch/A a   switch/B b
        button/A a   button/B b
        ground/GND t
        lamp/1 a     lamp/2 b
        fuse/1 a     fuse/2 b
    }
}

# load -- parse the vendored library once into SYM.
proc ::schem::ksym::load {{path ""}} {
    variable SYM ; variable LOADED
    if {$LOADED} return
    if {$path eq ""} {
        variable DIR
        set path [file join $DIR .. lib symbols standard.kicad_lib]
    }
    set fh [open $path r] ; set lines [split [read $fh] \n] ; close $fh
    set type "" ; set cur ""
    foreach ln $lines {
        if {[string match "SCHEMTYPE *" $ln]} {
            set type [lindex $ln 1] ; set cur ""
            continue
        }
        if {$type eq ""} continue
        if {[string match "DEF *" $ln]} { set cur [dict create prims {} pins {}] ; continue }
        if {$cur eq ""} continue
        switch -- [string index $ln 0] {
            P { dict update cur prims pp { lappend pp [::schem::ksym::Poly $ln] } }
            S { dict update cur prims pp { lappend pp [::schem::ksym::Rect $ln] } }
            C { dict update cur prims pp { lappend pp [::schem::ksym::Circ $ln] } }
            A { dict update cur prims pp { lappend pp [::schem::ksym::Arc  $ln] } }
            X { ::schem::ksym::Pin cur $type $ln }
        }
        if {[string match "ENDDEF*" $ln]} {
            set SYM($type) [::schem::ksym::Finish $cur]
            set type "" ; set cur ""
        }
    }
    set LOADED 1
}

# --- record parsers (return {kind ...}); coords kept in KiCad space ----------
proc ::schem::ksym::Poly {ln} {
    set f [regexp -all -inline {\S+} $ln]
    set n [lindex $f 1] ; set thk [lindex $f 4]
    set pts {} ; set i 5
    for {set k 0} {$k < $n} {incr k} {
        lappend pts [lindex $f $i] [lindex $f [expr {$i+1}]] ; incr i 2
    }
    set fill [lindex $f $i]
    return [list poly $pts [expr {$fill eq "F"}] $thk]
}
proc ::schem::ksym::Rect {ln} {
    set f [regexp -all -inline {\S+} $ln]
    return [list rect [lindex $f 1] [lindex $f 2] [lindex $f 3] [lindex $f 4] \
        [expr {[lindex $f 7] eq "F"}]]
}
proc ::schem::ksym::Circ {ln} {
    set f [regexp -all -inline {\S+} $ln]
    return [list circ [lindex $f 1] [lindex $f 2] [lindex $f 3] \
        [expr {[lindex $f 7] eq "F"}]]
}
proc ::schem::ksym::Arc {ln} {
    # A cx cy r a1 a2 u c thk fill sx sy ex ey
    set f [regexp -all -inline {\S+} $ln]
    return [list arc [lindex $f 1] [lindex $f 2] [lindex $f 3] \
        [lindex $f 10] [lindex $f 11] [lindex $f 12] [lindex $f 13]]
}
proc ::schem::ksym::Pin {curVar type ln} {
    upvar 1 $curVar cur
    variable PINMAP
    set f [regexp -all -inline {\S+} $ln]
    set name [lindex $f 1] ; set num [lindex $f 2]
    set px [lindex $f 3] ; set py [lindex $f 4]
    set len [lindex $f 5] ; set dir [lindex $f 6]
    # the pin's connection point is at the FAR end of the stub
    switch -- $dir {
        R { set ex [expr {$px+$len}] ; set ey $py }
        L { set ex [expr {$px-$len}] ; set ey $py }
        U { set ex $px ; set ey [expr {$py+$len}] }
        D { set ex $px ; set ey [expr {$py-$len}] }
        default { set ex $px ; set ey $py }
    }
    # resolve the engine terminal name
    set key "$type/$name"
    set knum "$type/#$num"
    if {[info exists PINMAP($key)]}      { set term $PINMAP($key) } \
    elseif {[info exists PINMAP($knum)]} { set term $PINMAP($knum) } \
    else { set term [string tolower $name] }
    # draw the stub as a polyline too
    dict update cur prims pp { lappend pp [list poly [list $px $py $ex $ey] 0 6] }
    dict update cur pins pm { dict set pm $term [list $ex $ey] }
}

# Finish -- compute the bounding box (KiCad space) for centring/scaling.
proc ::schem::ksym::Finish {cur} {
    set xs {} ; set ys {}
    foreach p [dict get $cur prims] {
        switch -- [lindex $p 0] {
            poly { foreach {x y} [lindex $p 1] { lappend xs $x ; lappend ys $y } }
            rect { lassign $p _ x1 y1 x2 y2 ; lappend xs $x1 $x2 ; lappend ys $y1 $y2 }
            circ { lassign $p _ x y r ; lappend xs [expr {$x-$r}] [expr {$x+$r}] ; lappend ys [expr {$y-$r}] [expr {$y+$r}] }
            arc  { lassign $p _ x y r ; lappend xs [expr {$x-$r}] [expr {$x+$r}] ; lappend ys [expr {$y-$r}] [expr {$y+$r}] }
        }
    }
    dict for {t xy} [dict get $cur pins] { lappend xs [lindex $xy 0] ; lappend ys [lindex $xy 1] }
    if {[llength $xs]} {
        set bbox [list [::tcl::mathfunc::min {*}$xs] [::tcl::mathfunc::min {*}$ys] \
                       [::tcl::mathfunc::max {*}$xs] [::tcl::mathfunc::max {*}$ys]]
    } else { set bbox {0 0 0 0} }
    dict set cur bbox $bbox
    return $cur
}

# has -- is there a KiCad symbol for this schem type?
proc ::schem::ksym::has {type} {
    ::schem::ksym::load
    variable SYM
    return [info exists SYM($type)]
}

# draw -- render symbol `type` centred at (cx,cy) on canvas c.
#   -scale S  : canvas px per 100 KiCad units (a resistor is ~200 units wide)
#   -rot deg  : 0/90/180/270   -color C   -tags {..}   -state ..(switch)
# Returns {pins {term {x y} ..} w .. h ..} with pin coords in canvas space.
proc ::schem::ksym::draw {c type cx cy args} {
    ::schem::ksym::load
    variable SYM
    if {![info exists SYM($type)]} { return "" }
    set o [dict create -scale 0.18 -rot 0 -color "#cfd4dd" -tags {} -state "" -width 0]
    dict for {k v} $args { dict set o $k $v }
    set s [dict get $o -scale] ; set deg [dict get $o -rot]
    set col [dict get $o -color] ; set tags [dict get $o -tags]
    set lw [expr {max(1, round(2*$s/0.18))}]
    set sym $SYM($type)
    lassign [dict get $sym bbox] bx1 by1 bx2 by2
    set mx [expr {($bx1+$bx2)/2.0}] ; set my [expr {($by1+$by2)/2.0}]
    # transform a KiCad point -> canvas point (centre, scale, flip Y, rotate)
    set tx {{x y} {
        upvar 1 mx mx my my s s deg deg cx cx cy cy
        set dx [expr {($x-$mx)*$s}] ; set dy [expr {-($y-$my)*$s}]
        switch -- $deg {
            90  { set nx [expr {-$dy}] ; set ny $dx }
            180 { set nx [expr {-$dx}] ; set ny [expr {-$dy}] }
            270 { set nx $dy ; set ny [expr {-$dx}] }
            default { set nx $dx ; set ny $dy }
        }
        return [list [expr {$cx+$nx}] [expr {$cy+$ny}]]
    }}
    foreach p [dict get $sym prims] {
        switch -- [lindex $p 0] {
            poly {
                lassign $p _ pts fill thk
                set co {}
                foreach {x y} $pts { lappend co {*}[apply $tx $x $y] }
                if {$fill} {
                    $c create polygon {*}$co -outline $col -fill $col -width $lw -tags $tags
                } else {
                    $c create line {*}$co -fill $col -width $lw -tags $tags
                }
            }
            rect {
                lassign $p _ x1 y1 x2 y2 fill
                lassign [apply $tx $x1 $y1] ax ay ; lassign [apply $tx $x2 $y2] bx by
                $c create rectangle $ax $ay $bx $by -outline $col -width $lw \
                    -fill [expr {$fill ? $col : ""}] -tags $tags
            }
            circ {
                lassign $p _ x y r fill
                lassign [apply $tx $x $y] ax ay ; set rr [expr {$r*$s}]
                $c create oval [expr {$ax-$rr}] [expr {$ay-$rr}] [expr {$ax+$rr}] [expr {$ay+$rr}] \
                    -outline $col -width $lw -fill [expr {$fill ? $col : ""}] -tags $tags
            }
            arc {
                lassign $p _ x y r sx sy ex ey
                # approximate the arc as a polyline through start, mid, end
                lassign [apply $tx $sx $sy] asx asy
                lassign [apply $tx $ex $ey] aex aey
                lassign [apply $tx $x $y] acx acy
                # midpoint on the arc: bulge from chord midpoint toward centre-opposite
                set mxp [expr {($asx+$aex)/2.0}] ; set myp [expr {($asy+$aey)/2.0}]
                set vx [expr {$mxp-$acx}] ; set vy [expr {$myp-$acy}]
                set vl [expr {hypot($vx,$vy)}] ; if {$vl < 1e-6} { set vl 1 }
                set rr [expr {$r*$s}]
                set bx [expr {$acx+$vx/$vl*$rr}] ; set by [expr {$acy+$vy/$vl*$rr}]
                $c create line $asx $asy $bx $by $aex $aey -smooth 1 -fill $col -width $lw -tags $tags
            }
        }
    }
    # pins in canvas space
    set pins [dict create]
    dict for {t xy} [dict get $sym pins] {
        dict set pins $t [apply $tx [lindex $xy 0] [lindex $xy 1]]
    }
    set w [expr {abs($bx2-$bx1)*$s}] ; set h [expr {abs($by2-$by1)*$s}]
    return [dict create pins $pins w $w h $h]
}

# Engine type -> vendored KiCad symbol name.  Types not listed fall back to the
# hand-drawn ::schem::sym::draw (relay, transformer, nixie, core, ...).
namespace eval ::schem::ksym {
    variable TYPEMAP
    array set TYPEMAP {
        resistor resistor  capacitor capacitor  inductor inductor
        diode diode  battery battery  vsource vsource
        bjt bjt_npn  mosfet nmos  switch switch  button button
        lamp lamp  fuse fuse  ground ground
    }
    # per-symbol scale tweak so the KiCad glyphs sit on Schem's ~20px grid at
    # the same visual weight as before (KiCad parts are ~200 units = 2 grid).
    variable BASESCALE 0.17
    # KiCad draws many 2-pin parts vertically; rotate these so they default to
    # a horizontal series orientation (left=in, right=out), which reads more
    # naturally for the rail-to-rail circuits beginners build.
    variable DEFROT
    array set DEFROT {resistor 90 capacitor 90 inductor 90 battery 90 vsource 90 fuse 90 lamp 90}
}

# unified draw: KiCad symbol when available, else the legacy hand-drawn one.
# Same return contract as ::schem::sym::draw {pins {term {dx dy}} w h}.
namespace eval ::schem::sym {}
proc ::schem::sym::draw2 {c type x y args} {
    variable ::schem::ksym::TYPEMAP
    variable ::schem::ksym::BASESCALE
    # parse a couple of opts we translate
    set scale 1.2 ; set rot 0 ; set color "#cfd4dd" ; set tags {} ; set state ""
    set label "" ; set value ""
    foreach {k v} $args {
        switch -- $k {
            -scale {set scale $v} -rot {set rot $v} -color {set color $v}
            -tags {set tags $v} -state {set state $v} -label {set label $v} -value {set value $v}
        }
    }
    if {[info exists TYPEMAP($type)] && [::schem::ksym::has $TYPEMAP($type)]} {
        set ks [expr {$scale*$BASESCALE}]
        variable ::schem::ksym::DEFROT
        set base [expr {[info exists DEFROT($type)] ? $DEFROT($type) : 0}]
        set erot [expr {($rot+$base)%360}]
        set r [::schem::ksym::draw $c $TYPEMAP($type) $x $y -scale $ks -rot $erot \
            -color $color -tags $tags -state $state]
        # labels (ref des above, value below), matching the old look
        if {$label ne "" || $value ne ""} {
            set hh [expr {[dict get $r h]/2.0 + 12}]
            if {$label ne ""} {
                $c create text $x [expr {$y-$hh}] -text $label -fill $color \
                    -font [list "DejaVu Sans" [expr {max(7,round(9*$scale/1.2))}]] -anchor s -tags $tags
            }
            if {$value ne ""} {
                $c create text $x [expr {$y+$hh}] -text $value -fill "#9aa0ab" \
                    -font [list "DejaVu Sans" [expr {max(6,round(8*$scale/1.2))}]] -anchor n -tags $tags
            }
        }
        # convert absolute pins to offsets relative to (x,y) for contract parity
        set pins [dict create]
        dict for {t xy} [dict get $r pins] {
            dict set pins $t [list [expr {[lindex $xy 0]-$x}] [expr {[lindex $xy 1]-$y}]]
        }
        return [dict create pins $pins w [dict get $r w] h [dict get $r h]]
    }
    # fallback to the legacy drawer
    return [::schem::sym::draw $c $type $x $y {*}$args]
}
