# lib/catalog.tcl --
#
# The circuit catalog: the standard *electrical assemblies* an engineer
# reaches for when building larger machines -- registers, arithmetic,
# counters, decoders and selectors.  Each is an ordinary Schem circuit
# (a bounded group of components exposing a terminal contract), built only
# from the relay logic and sequential cells in lib/logic.tcl, which are
# themselves built only from relays, contacts and pull-downs.  Nothing here
# is a software abstraction -- they compose as Component -> Circuit -> Panel.
#
#   source lib/logic.tcl ; source lib/catalog.tcl
#
# Width is a parameter `n`.  Signal convention is the logic library's:
# active-high levels (HIGH ~ VCC, LOW ~ 0 V); inputs drive coils, outputs are
# levels, so cells chain directly.  All cells expose VCC and GND rails.

package require Tcl

# ---- register: n bits of clocked storage --------------------------------
# A bank of edge-triggered D flip-flops on a common clock.  On each rising
# CLK edge, Q<i> captures D<i> and holds it.  Ports: D0..Dn-1 CLK Q0..Qn-1.
proc ::schem::lib::register {{name reg} {n 4}} {
    set c [::schem::circuit $name]
    Rails $c
    $c add junction CK ; $c expose CLK CK.t
    for {set i 0} {$i < $n} {incr i} {
        set ff [$c instantiate [d_flipflop] FF$i]
        RailUp $c $ff
        $c wire CK.t [dict get $ff CLK]
        $c expose D$i [dict get $ff D]
        $c expose Q$i [dict get $ff Q]
        $c expose NQ$i [dict get $ff NQ]
    }
    return $c
}

# ---- adder: an n-bit ripple-carry adder ---------------------------------
# n full adders chained carry-to-carry.  Ports: A0..An-1 B0..Bn-1 CIN
# S0..Sn-1 COUT.  SUM = A + B + CIN.
proc ::schem::lib::adder {{name adder} {n 4}} {
    set c [::schem::circuit $name]
    Rails $c
    set carry ""
    for {set i 0} {$i < $n} {incr i} {
        set fa [$c instantiate [full_adder] FA$i]
        RailUp $c $fa
        $c expose A$i [dict get $fa A]
        $c expose B$i [dict get $fa B]
        $c expose S$i [dict get $fa SUM]
        if {$carry eq ""} {
            $c expose CIN [dict get $fa CIN]
        } else {
            $c wire $carry [dict get $fa CIN]
        }
        set carry [dict get $fa COUT]
    }
    $c expose COUT $carry
    return $c
}

# ---- counter: an n-bit binary ripple counter ----------------------------
# n toggle flip-flops; stage i+1 is clocked by stage i's ~Q.  Ports: CLK
# Q0..Qn-1 (Q0 = least-significant bit).
proc ::schem::lib::counter {{name counter} {n 4}} {
    set c [::schem::circuit $name]
    Rails $c
    set prevnq ""
    for {set i 0} {$i < $n} {incr i} {
        set ff [$c instantiate [t_flipflop] T$i]
        RailUp $c $ff
        $c expose Q$i [dict get $ff Q]
        if {$prevnq eq ""} {
            $c expose CLK [dict get $ff CLK]
        } else {
            $c wire $prevnq [dict get $ff CLK]
        }
        set prevnq [dict get $ff NQ]
    }
    return $c
}

# Tree -- a binary tree of SPDT relay contacts, `n` levels deep, switched by
# `n` address bits.  Returns the 2^n leaf nodes.  Level 0 (the root split) is
# the most-significant address bit.  Each level i is driven by address bit i;
# the coil terminals for bit i are appended to coils($i) for the caller to
# fan an address line into.  Used by both the decoder and the selector.
proc ::schem::lib::Tree {c root n prefix coilsVar} {
    upvar 1 $coilsVar coils
    variable COIL ; variable PICK
    set lines [list $root]
    for {set i 0} {$i < $n} {incr i} {
        set new {} ; set j 0
        foreach line $lines {
            set r ${prefix}${i}_${j}
            $c add relay $r -coil $COIL -pickup $PICK
            $c wire $r.c2 GR.t
            dict lappend coils $i $r.c1
            $c wire $line $r.com
            lappend new $r.nc      ;# this address bit = 0
            lappend new $r.no      ;# this address bit = 1
            incr j
        }
        set lines $new
    }
    return $lines
}

# FanAddr -- expose address inputs A0..An-1, each fanned to all the coils it
# drives in the tree (collected in coils).
proc ::schem::lib::FanAddr {c n coilsVar} {
    upvar 1 $coilsVar coils
    for {set i 0} {$i < $n} {incr i} {
        $c add junction A$i
        foreach t [expr {[dict exists $coils $i] ? [dict get $coils $i] : {}}] {
            $c wire A$i.t $t
        }
        $c expose A$i A$i.t
    }
}

# ---- decoder: n-to-2^n one-hot address decoder --------------------------
# Drives exactly one of Y0..Y(2^n-1) HIGH, selected by the binary address on
# A0..An-1 (A0 most significant).  Ports: A0..An-1 Y0..Y(2^n-1).
proc ::schem::lib::decoder {{name dec} {n 2}} {
    variable PULL
    set c [::schem::circuit $name]
    Rails $c
    set coils [dict create]
    set leaves [Tree $c VR.t $n K $coils]   ;# VCC reaches one leaf per address
    set k 0
    foreach leaf $leaves {
        $c add resistor PD$k -r $PULL
        $c wire $leaf PD$k.a ; $c wire PD$k.b GR.t
        $c expose Y$k PD$k.a
        incr k
    }
    FanAddr $c $n $coils
    return $c
}

# ---- selector (multiplexer): route one of 2^n inputs to OUT -------------
# OUT follows the data input I<k> chosen by the address A0..An-1.  Ports:
# I0..I(2^n-1) A0..An-1 OUT.
proc ::schem::lib::selector {{name sel} {n 1}} {
    variable PULL
    set c [::schem::circuit $name]
    Rails $c
    $c add junction MX
    $c add resistor PD -r $PULL
    $c wire MX.t PD.a ; $c wire PD.b GR.t
    $c expose OUT MX.t
    set coils [dict create]
    set leaves [Tree $c MX.t $n K $coils]   ;# OUT connects to one leaf (input)
    set k 0
    foreach leaf $leaves { $c expose I$k $leaf ; incr k }
    FanAddr $c $n $coils
    return $c
}
