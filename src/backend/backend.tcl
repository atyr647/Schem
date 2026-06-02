# backend.tcl --
#
# Backends consume the Circuit IR (src/compile.tcl) and emit a target.  They
# are interchangeable: each is a proc ::schem::backend::<name> {cir} returning
# the emitted text, registered just by existing.  The IR is the contract, so
# adding C / WASM / HDL later means adding a sibling proc -- no engine change.
#
#     schematic -> Circuit IR ->  [ zig | dcref | c | wasm | hdl | ... ]
#
#   schem::emit $schematic zig        ;# -> Zig source for the DC solve
#   schem::backends                   ;# -> list of available targets

namespace eval ::schem::backend {}

# emit -- compile a schematic to its Circuit IR and run the named backend.
proc ::schem::emit {schem target args} {
    if {[llength [info commands ::schem::backend::$target]] == 0} {
        return -code error "unknown backend \"$target\" (have: [::schem::backends])"
    }
    return [::schem::backend::$target [$schem compile] {*}$args]
}

# backends -- the registered backend names.
proc ::schem::backends {} {
    set out {}
    foreach c [info commands ::schem::backend::*] {
        set n [namespace tail $c]
        if {[string match {[a-z]*} $n]} { lappend out $n }   ;# skip helpers (Capitalised)
    }
    return [lsort $out]
}

# ====================================================================
#  Shared DC lowering: classify the IR into the pieces a DC solver needs.
# ====================================================================
#
# Returns a dict:
#   n         non-ground node count
#   sz        n + (number of branch-current unknowns)
#   conds     {na nb g label}              always-on conductances
#   branches  {p q emf rs owner}           voltage-source / ideal-conductor rows
#   relays    {c1 c2 rcoil pickup dropout com no nc name}
#   diodes    {a k is n rs bv name}
#
# This is the full DC behaviour of every element: resistors/coils/closed
# switches/wires are conductances; sources/meters/protection/ideal conductors
# /transformer windings (shorts at DC) are branches; relay contacts are
# state-controlled conductances; diodes are nonlinear.  Capacitors are open at
# DC and drop out.  Nothing is refused -- every part has a DC lowering.
proc ::schem::backend::LowerDC {cir} {
    set conds {} ; set branches {} ; set relays {} ; set diodes {} ; set mosfets {} ; set bjts {} ; set protect {} ; set buffers {}
    foreach e [dict get $cir elements] {
        set nm [dict get $e name]
        if {[dict exists $e nodes]} { set nd [dict get $e nodes] }
        switch [dict get $e class] {
            conductance {
                lappend conds [list [dict get $nd a] [dict get $nd b] [dict get $e g] $nm]
            }
            source {
                lappend branches [list [dict get $nd pos] [dict get $nd neg] [dict get $e emf] [dict get $e rs] $nm]
            }
            switch {
                if {[dict get $e state] in {closed pressed}} {
                    lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/[dict get $e r_closed]}] $nm]
                }
            }
            relay {
                set cn [dict get $e coil nodes] ; set kn [dict get $e contact nodes]
                lappend conds [list [dict get $cn c1] [dict get $cn c2] [dict get $e coil g] $nm.coil]
                lappend relays [list [dict get $cn c1] [dict get $cn c2] [dict get $e coil r] \
                    [dict get $e pickup] [dict get $e dropout] \
                    [dict get $kn com] [dict get $kn no] [dict get $kn nc] $nm]
            }
            nonlinear {
                set m [dict get $e model]
                lappend diodes [list [dict get $nd a] [dict get $nd k] \
                    [dict get $m is] [dict get $m n] [dict get $m rs] [dict get $m bv] $nm]
            }
            transistor {
                set m [dict get $e model]
                if {[dict get $e type] eq "bjt"} {
                    lappend bjts [list [dict get $nd b] [dict get $nd c] [dict get $nd e] \
                        [dict get $m is] [dict get $m beta] [dict get $m n] [dict get $m vaf] [dict get $m pnp] $nm]
                } else {
                    lappend mosfets [list [dict get $nd g] [dict get $nd d] [dict get $nd s] \
                        [dict get $m vto] [dict get $m kp] [dict get $m lambda] [dict get $m pmos] $nm]
                }
            }
            reactive {
                if {[dict get $e type] eq "inductor"} {
                    set r [dict get $e r]
                    if {$r > 0} { lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/$r}] $nm] } \
                    else { lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm] }
                }
                # capacitor: open at DC -> no stamp
            }
            coupled {
                # transformer windings are shorts at DC (mutual coupling is a
                # transient effect): two ideal 0 V branches.
                lappend branches [list [dict get $nd p1] [dict get $nd n1] 0.0 0.0 $nm.pri]
                lappend branches [list [dict get $nd p2] [dict get $nd n2] 0.0 0.0 $nm.sec]
            }
            protective {
                if {[dict get $e state] in {intact closed}} {
                    lappend protect [list [llength $branches] [dict get $e rating] [dict get $e i2t] $nm]
                    lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm]
                }
            }
            meter {
                lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm]
            }
            conductor {
                set r [dict get $e r]
                if {$r > 0} { lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/$r}] $nm] } \
                else { lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm] }
            }
            memory {
                # A memory chip at DC: address/data-in/control pins are weak
                # pull-downs (a real high input resistance), and each data-out
                # pin is a logic driver to ground -- vhigh for a stored 1, else
                # 0, through the output resistance.  The IR is stateless, so the
                # static operating point reads the power-on contents (all 0):
                # the DO drivers all sit at 0 V.  (Writes are clocked events,
                # not part of a single DC solve -- the engine agrees.)
                set gin [expr {1.0/[dict get $e rin]}]
                set ro  [dict get $e rout]
                foreach a [dict get $e address] { lappend conds [list $a 0 $gin $nm.in] }
                foreach d [dict get $e di]      { lappend conds [list $d 0 $gin $nm.in] }
                lappend conds [list [dict get $e we]  0 $gin $nm.in]
                lappend conds [list [dict get $e clk] 0 $gin $nm.in]
                if {[dict get $e mode] eq "tape"} {
                    lappend conds [list [dict get $e move left]  0 $gin $nm.in]
                    lappend conds [list [dict get $e move right] 0 $gin $nm.in]
                }
                foreach d [dict get $e do] { lappend branches [list $d 0 0.0 $ro $nm.do] }
            }
            buffer {
                # A tri-state buffer: in/oe are weak pull-down senses; out is a
                # settable/openable branch -- driven through rout when enabled,
                # else high-impedance (the branch is forced to I=0).  The
                # enable/drive decision is the fixed point's (bufdrv), like a
                # protective device's open/closed state.
                set gin [expr {1.0/[dict get $e rin]}]
                lappend conds [list [dict get $e in] 0 $gin $nm.in]
                lappend conds [list [dict get $e oe] 0 $gin $nm.in]
                lappend buffers [list [llength $branches] [dict get $e in] [dict get $e oe] \
                    [dict get $e vhigh] [dict get $e rout] $nm]
                lappend branches [list [dict get $e out] 0 0.0 [dict get $e rout] $nm.out]
            }
        }
    }
    set n [dict get $cir nodes count]
    return [dict create n $n sz [expr {$n + [llength $branches]}] \
        conds $conds branches $branches relays $relays diodes $diodes mosfets $mosfets bjts $bjts protect $protect buffers $buffers]
}

# DiodeGI -- junction current Id and small-signal conductance gj at junction
# voltage vj (Shockley + optional Zener breakdown), then the terminal
# companion folding series resistance rs.  Returns {Gt Ieq Id}.
proc ::schem::backend::DiodeGI {vj is n rs bv} {
    set Vt [expr {0.025852 * $n}]
    set ef [expr {exp(min($vj/$Vt, 80.0))}]
    set Id [expr {$is*($ef-1.0)}]
    set gj [expr {$is*$ef/$Vt}]
    if {$bv > 0 && $vj < -$bv} {
        set eb [expr {exp(min((-$vj-$bv)/$Vt, 80.0))}]
        set Id [expr {$Id - $is*($eb-1.0)}]
        set gj [expr {$gj + $is*$eb/$Vt}]
    }
    if {$gj < 1e-12} { set gj 1e-12 }
    set Gt  [expr {$gj/(1.0 + $gj*$rs)}]
    set vd0 [expr {$vj + $Id*$rs}]
    return [list $Gt [expr {$Id - $Gt*$vd0}] $Id]
}

# MosfetGI -- drain current Id (D→S convention), transconductance gm, and
# output conductance gds from the Shichman-Hodges model.  Returns {Id gm gds}.
# pmos non-zero: negate voltages internally, negate returned Id.
proc ::schem::backend::MosfetGI {vgs vds vto kp lambda pmos} {
    if {$pmos} { set vgs [expr {-$vgs}] ; set vds [expr {-$vds}] }
    set vov [expr {$vgs - $vto}]
    if {$vov <= 0.0} {
        set Id 0.0 ; set gm 0.0 ; set gds 1e-12
    } elseif {$vds <= 0.0} {
        set gds [expr {$kp * $vov}]
        set Id  [expr {$gds * $vds}]
        set gm  0.0
    } elseif {$vds < $vov} {
        set lv [expr {1.0 + $lambda * $vds}]
        set Id  [expr {$kp * ($vov*$vds - $vds*$vds*0.5) * $lv}]
        set gm  [expr {$kp * $vds * $lv}]
        set gds [expr {$kp*($vov-$vds)*$lv + $kp*($vov*$vds-$vds*$vds*0.5)*$lambda}]
    } else {
        set lv [expr {1.0 + $lambda * $vds}]
        set Id  [expr {$kp * 0.5 * $vov*$vov * $lv}]
        set gm  [expr {$kp * $vov * $lv}]
        set gds [expr {$kp * 0.5 * $vov*$vov * $lambda}]
    }
    if {$gds < 1e-12} { set gds 1e-12 }
    if {$pmos} { set Id [expr {-$Id}] }
    return [list $Id $gm $gds]
}

# BjtGI -- BJT Ebers-Moll: collector current Ic (C→E convention), base
# current Ib, transconductance gm, base-emitter conductance gbe, and
# Early-effect collector-emitter conductance gce, at (vbe, vce).
# pnp non-zero: negate voltages internally, negate returned Ic and Ib.
proc ::schem::backend::BjtGI {vbe vce is beta nf vaf pnp} {
    if {$pnp} { set vbe [expr {-$vbe}] ; set vce [expr {-$vce}] }
    set Vt [expr {0.025852 * $nf}]
    set ef [expr {exp(min($vbe/$Vt, 80.0))}]
    set early [expr {$vaf > 0 ? max(0.01, 1.0 + $vce/$vaf) : 1.0}]
    set Ic  [expr {$is * ($ef - 1.0) * $early}]
    set gm  [expr {max($is * $ef / $Vt * $early, 1e-12)}]
    set gce [expr {$vaf > 0 ? max($is * ($ef - 1.0) / $vaf, 1e-12) : 1e-12}]
    set Ib  [expr {$Ic / $beta}]
    set gbe [expr {max($gm / $beta, 1e-12)}]
    if {$pnp} { set Ic [expr {-$Ic}] ; set Ib [expr {-$Ib}] }
    return [list $Ic $Ib $gm $gbe $gce]
}

# ====================================================================
#  dcref -- reference DC backend (in Tcl) that solves straight from the IR.
# ====================================================================
#
# The same algorithm the engine uses (outer fixed-point over relay state,
# inner Newton over diodes) but driven only by the Circuit IR.  It proves the
# IR carries enough to reproduce a full DC solve, and is the oracle the code
# emitters are checked against.  Returns a dict node-id -> voltage.

# --- shared MNA helpers (used by dcref and zig backends) ------------
proc ::schem::backend::StampG {Avar na nb g} {
    upvar 1 $Avar A
    if {$na != 0} { ::schem::la::spacc A [expr {$na-1}] [expr {$na-1}] $g }
    if {$nb != 0} { ::schem::la::spacc A [expr {$nb-1}] [expr {$nb-1}] $g }
    if {$na != 0 && $nb != 0} {
        ::schem::la::spacc A [expr {$na-1}] [expr {$nb-1}] [expr {-$g}]
        ::schem::la::spacc A [expr {$nb-1}] [expr {$na-1}] [expr {-$g}]
    }
}
proc ::schem::backend::Nv {x nid} { return [expr {$nid == 0 ? 0.0 : [lindex $x [expr {$nid-1}]]}] }

# zf -- format a number as a valid Zig f64 literal.
proc ::schem::backend::Zf {v} {
    set s [format %.12g [expr {double($v)}]]
    if {![string match *.* $s] && ![string match *e* $s] && ![string match *E* $s]} { append s .0 }
    return $s
}

# ====================================================================
#  Zig backend -- emit a self-contained Zig program that solves the DC
#  operating point: outer fixed-point over relay state, inner Newton over
#  diodes, exactly as the engine (and dcref) do.
# ====================================================================
