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
    set conds {} ; set branches {} ; set relays {} ; set diodes {} ; set protect {}
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
        }
    }
    set n [dict get $cir nodes count]
    return [dict create n $n sz [expr {$n + [llength $branches]}] \
        conds $conds branches $branches relays $relays diodes $diodes protect $protect]
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

# ====================================================================
#  dcref -- reference DC backend (in Tcl) that solves straight from the IR.
# ====================================================================
#
# The same algorithm the engine uses (outer fixed-point over relay state,
# inner Newton over diodes) but driven only by the Circuit IR.  It proves the
# IR carries enough to reproduce a full DC solve, and is the oracle the code
# emitters are checked against.  Returns a dict node-id -> voltage.
proc ::schem::backend::dcref {cir} {
    variable ::schem::RSMALL
    set L [LowerDC $cir]
    set N [dict get $L n] ; set SZ [dict get $L sz]
    if {$SZ == 0} { return [dict create 0 0.0] }
    set conds [dict get $L conds] ; set branches [dict get $L branches]
    set relays [dict get $L relays] ; set diodes [dict get $L diodes]
    set protect [dict get $L protect]
    set gc [expr {1.0/$RSMALL}]

    set energized [lrepeat [llength $relays] 0]
    set diodeV    [lrepeat [llength $diodes] 0.0]
    set fbopen    [dict create]   ;# protective branch index -> 1 once tripped
    set x {}

    for {set outer 0} {$outer < 200} {incr outer} {
        for {set newton 0} {$newton < 100} {incr newton} {
            unset -nocomplain A ; array set A {}
            set z [lrepeat $SZ 0.0]
            for {set i 0} {$i < $N} {incr i} { ::schem::la::spacc A $i $i 1e-12 }
            foreach c $conds {
                lassign $c na nb g _
                StampG A $na $nb $g
            }
            for {set ri 0} {$ri < [llength $relays]} {incr ri} {
                lassign [lindex $relays $ri] c1 c2 rc pu do com no nc nm
                if {[lindex $energized $ri]} { StampG A $com $no $gc } else { StampG A $com $nc $gc }
            }
            for {set di 0} {$di < [llength $diodes]} {incr di} {
                lassign [lindex $diodes $di] na nk is nf rs bv nm
                lassign [DiodeGI [lindex $diodeV $di] $is $nf $rs $bv] Gt Ieq
                StampG A $na $nk $Gt
                if {$na != 0} { lset z [expr {$na-1}] [expr {[lindex $z [expr {$na-1}]] - $Ieq}] }
                if {$nk != 0} { lset z [expr {$nk-1}] [expr {[lindex $z [expr {$nk-1}]] + $Ieq}] }
            }
            set k 0
            foreach br $branches {
                lassign $br p q emf rs _
                set row [expr {$N + $k}]
                if {[dict exists $fbopen $k]} {
                    # blown/tripped protective device: force I_branch = 0 (open).
                    ::schem::la::spacc A $row $row 1.0
                    lset z $row 0.0
                } else {
                    if {$p != 0} { ::schem::la::spacc A [expr {$p-1}] $row 1.0 ; ::schem::la::spacc A $row [expr {$p-1}] 1.0 }
                    if {$q != 0} { ::schem::la::spacc A [expr {$q-1}] $row -1.0 ; ::schem::la::spacc A $row [expr {$q-1}] -1.0 }
                    if {$rs != 0} { ::schem::la::spacc A $row $row [expr {-$rs}] }
                    lset z $row $emf
                }
                incr k
            }
            set x [::schem::la::solve_sparse A $z $SZ]

            set maxd 0.0
            for {set di 0} {$di < [llength $diodes]} {incr di} {
                lassign [lindex $diodes $di] na nk is nf rs bv nm
                set vd [expr {[Nv $x $na] - [Nv $x $nk]}]
                set vold [lindex $diodeV $di]
                if {$rs > 0} {
                    lassign [DiodeGI $vold $is $nf $rs $bv] Gt Ieq
                    set vnew [expr {$vd - ($Gt*$vd + $Ieq)*$rs}]
                } else { set vnew $vd }
                if {$vnew - $vold > 0.5} { set vnew [expr {$vold + 0.5}] }
                if {$vold - $vnew > 0.5} { set vnew [expr {$vold - 0.5}] }
                set d [expr {abs($vnew-$vold)}] ; if {$d > $maxd} { set maxd $d }
                lset diodeV $di $vnew
            }
            if {$maxd < 1e-9} break
        }
        set changed 0
        for {set ri 0} {$ri < [llength $relays]} {incr ri} {
            lassign [lindex $relays $ri] c1 c2 rc pu do com no nc nm
            set ic [expr {abs([Nv $x $c1] - [Nv $x $c2]) / $rc}]
            set was [lindex $energized $ri]
            set now [expr {$was ? ($ic >= $do) : ($ic >= $pu)}]
            if {$now != $was} { lset energized $ri $now ; set changed 1 }
        }
        # Protective devices blow/trip on over-rating current.  At DC (steady
        # state = infinite time) this is instantaneous regardless of i2t, like
        # the engine: the branch current is the unknown at row N+branchIdx.
        foreach p $protect {
            lassign $p bi rating i2t nm
            if {[dict exists $fbopen $bi]} continue
            if {abs([lindex $x [expr {$N + $bi}]]) > $rating} { dict set fbopen $bi 1 ; set changed 1 }
        }
        if {!$changed} break
    }
    set v [dict create 0 0.0]
    for {set i 1} {$i <= $N} {incr i} { dict set v $i [lindex $x [expr {$i-1}]] }
    return $v
}

# my_stampG / nv -- helpers for the reference backend (node ids; 0 = ground).
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
proc ::schem::backend::zig {cir args} {
    # schem::emit $s zig                       -> DC operating point
    # schem::emit $s zig -transient -duration T -dt DT  -> transient stepper
    set transient 0 ; set duration 0.01 ; set dt 1e-4 ; set events {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        switch -- [lindex $args $i] {
            -transient { set transient 1 }
            -duration  { set duration [lindex $args [incr i]] }
            -dt        { set dt [lindex $args [incr i]] }
            -events    { set events [lindex $args [incr i]] }
            default    { return -code error "zig: unknown option [lindex $args $i]" }
        }
    }
    if {$transient} { return [::schem::backend::ZigTran $cir $duration $dt $events] }
    variable ::schem::RSMALL
    set L [LowerDC $cir]
    set N [dict get $L n] ; set SZ [dict get $L sz]
    set conds [dict get $L conds] ; set branches [dict get $L branches]
    set relays [dict get $L relays] ; set diodes [dict get $L diodes]
    set protect [dict get $L protect]
    set NR [llength $relays] ; set ND [llength $diodes] ; set NP [llength $protect]
    set name [dict get $cir name]
    # map branch index -> protective index (which branches can blow/trip)
    set b2p [dict create] ; set pj 0
    foreach p $protect { dict set b2p [lindex $p 0] $pj ; incr pj }

    # --- metadata arrays for relays and diodes ---
    proc Zarr {ty vals} { return "\[[llength $vals]\]$ty{[join $vals {, }]}" }
    set r_c1 {} ; set r_c2 {} ; set r_rc {} ; set r_pu {} ; set r_do {}
    set r_com {} ; set r_no {} ; set r_nc {}
    foreach r $relays {
        lassign $r c1 c2 rc pu do com no nc nm
        lappend r_c1 $c1 ; lappend r_c2 $c2 ; lappend r_rc [Zf $rc]
        lappend r_pu [Zf $pu] ; lappend r_do [Zf $do]
        lappend r_com $com ; lappend r_no $no ; lappend r_nc $nc
    }
    set d_a {} ; set d_k {} ; set d_is {} ; set d_n {} ; set d_rs {} ; set d_bv {}
    foreach d $diodes {
        lassign $d na nk is nf rs bv nm
        lappend d_a $na ; lappend d_k $nk ; lappend d_is [Zf $is]
        lappend d_n [Zf $nf] ; lappend d_rs [Zf $rs] ; lappend d_bv [Zf $bv]
    }

    # --- assemble() body: base conductances + branches (straight-line) ---
    set base {}
    lappend base "    // base conductances (resistors, coils, closed switches, wires)"
    foreach c $conds {
        lassign $c na nb g nm
        lappend base "    stampG(a, $na, $nb, [Zf $g]); // $nm"
    }
    lappend base "    // voltage-source / ideal-conductor branches"
    set k 0
    foreach br $branches {
        lassign $br p q emf rs nm
        set row [expr {$N+$k}]
        if {[dict exists $b2p $k]} {
            # protective device: open (I=0) once blown/tripped, else conduct.
            lappend base "    if (fb_open\[[dict get $b2p $k]\]) { a\[$row*SZ+$row\] += 1.0; z\[$row\] = 0.0; } else stampBranch(a, z, $row, $p, $q, [Zf $emf], [Zf $rs]); // $nm"
        } else {
            lappend base "    stampBranch(a, z, $row, $p, $q, [Zf $emf], [Zf $rs]); // $nm"
        }
        incr k
    }

    # --- per-node print lines ---
    set prints {}
    dict for {nid terms} [dict get $cir nodes map] {
        if {$nid == 0} continue
        lappend prints "    // N$nid : [join $terms { }]"
        lappend prints "    try stdout.print(\"  N{d} = {d:.4} V\\n\", .{ $nid, z\[[expr {$nid-1}]\] });"
    }

    set S {}
    lappend S "// Generated by Schem -- DC operating point of \"$name\""
    lappend S "// Derived from the Circuit IR; the .schem schematic is the source."
    lappend S "// $N node(s), $NR relay(s), $ND diode(s); SZ=$SZ unknowns.  Build: zig run this.zig"
    lappend S "const std = @import(\"std\");"
    lappend S ""
    lappend S "const N: usize = $N;"
    lappend S "const SZ: usize = $SZ;"
    lappend S "const NR: usize = $NR;"
    lappend S "const ND: usize = $ND;"
    lappend S "const NP: usize = $NP;"
    lappend S "const RSMALL: f64 = [Zf $RSMALL];"
    lappend S ""
    if {$NP} {
        set fb_row {} ; set fb_rating {}
        foreach p $protect { lappend fb_row [expr {$N + [lindex $p 0]}] ; lappend fb_rating [Zf [lindex $p 1]] }
        lappend S "const fb_row = [Zarr usize $fb_row];"
        lappend S "const fb_rating = [Zarr f64 $fb_rating];"
        lappend S "var fb_open = \[_\]bool{false} ** NP;"
    }
    if {$NR} {
        lappend S "const r_c1 = [Zarr usize $r_c1];"
        lappend S "const r_c2 = [Zarr usize $r_c2];"
        lappend S "const r_rc = [Zarr f64 $r_rc];"
        lappend S "const r_pu = [Zarr f64 $r_pu];"
        lappend S "const r_do = [Zarr f64 $r_do];"
        lappend S "const r_com = [Zarr usize $r_com];"
        lappend S "const r_no = [Zarr usize $r_no];"
        lappend S "const r_nc = [Zarr usize $r_nc];"
        lappend S "var energized = \[_\]bool{false} ** NR;"
    }
    if {$ND} {
        lappend S "const d_a = [Zarr usize $d_a];"
        lappend S "const d_k = [Zarr usize $d_k];"
        lappend S "const d_is = [Zarr f64 $d_is];"
        lappend S "const d_n = [Zarr f64 $d_n];"
        lappend S "const d_rs = [Zarr f64 $d_rs];"
        lappend S "const d_bv = [Zarr f64 $d_bv];"
        lappend S "var diodeV = \[_\]f64{0} ** ND;"
    }
    lappend S ""
    lappend S "fn nv(z: \[\]const f64, nid: usize) f64 { return if (nid == 0) 0.0 else z\[nid - 1\]; }"
    lappend S "fn stampG(a: \[\]f64, na: usize, nb: usize, g: f64) void {"
    lappend S "    if (na != 0) a\[(na - 1) * SZ + (na - 1)\] += g;"
    lappend S "    if (nb != 0) a\[(nb - 1) * SZ + (nb - 1)\] += g;"
    lappend S "    if (na != 0 and nb != 0) { a\[(na-1)*SZ+(nb-1)\] -= g; a\[(nb-1)*SZ+(na-1)\] -= g; }"
    lappend S "}"
    lappend S "fn stampBranch(a: \[\]f64, z: \[\]f64, row: usize, p: usize, q: usize, emf: f64, rs: f64) void {"
    lappend S "    if (p != 0) { a\[(p-1)*SZ+row\] += 1.0; a\[row*SZ+(p-1)\] += 1.0; }"
    lappend S "    if (q != 0) { a\[(q-1)*SZ+row\] -= 1.0; a\[row*SZ+(q-1)\] -= 1.0; }"
    lappend S "    if (rs != 0) a\[row*SZ+row\] -= rs;"
    lappend S "    z\[row\] = emf;"
    lappend S "}"
    if {$ND} {
        lappend S "const DG = struct { gt: f64, ieq: f64 };"
        lappend S "fn diodeComp(d: usize, vj: f64) DG {"
        lappend S "    const Vt = 0.025852 * d_n\[d\];"
        lappend S "    const ef = @exp(@min(vj / Vt, 80.0));"
        lappend S "    var Id = d_is\[d\] * (ef - 1.0);"
        lappend S "    var gj = d_is\[d\] * ef / Vt;"
        lappend S "    if (d_bv\[d\] > 0 and vj < -d_bv\[d\]) {"
        lappend S "        const eb = @exp(@min((-vj - d_bv\[d\]) / Vt, 80.0));"
        lappend S "        Id -= d_is\[d\] * (eb - 1.0);"
        lappend S "        gj += d_is\[d\] * eb / Vt;"
        lappend S "    }"
        lappend S "    if (gj < 1e-12) gj = 1e-12;"
        lappend S "    const gt = gj / (1.0 + gj * d_rs\[d\]);"
        lappend S "    return .{ .gt = gt, .ieq = Id - gt * (vj + Id * d_rs\[d\]) };"
        lappend S "}"
    }
    lappend S ""
    lappend S "fn solve(a: \[\]f64, z: \[\]f64, n: usize) void {"
    lappend S "    var k: usize = 0;"
    lappend S "    while (k < n) : (k += 1) {"
    lappend S "        var piv = k; var best = @abs(a\[k*n+k\]);"
    lappend S "        var i = k + 1;"
    lappend S "        while (i < n) : (i += 1) { const v = @abs(a\[i*n+k\]); if (v > best) { best = v; piv = i; } }"
    lappend S "        if (piv != k) {"
    lappend S "            var c: usize = 0;"
    lappend S "            while (c < n) : (c += 1) { const t = a\[k*n+c\]; a\[k*n+c\] = a\[piv*n+c\]; a\[piv*n+c\] = t; }"
    lappend S "            const tz = z\[k\]; z\[k\] = z\[piv\]; z\[piv\] = tz;"
    lappend S "        }"
    lappend S "        const pv = a\[k*n+k\];"
    lappend S "        i = k + 1;"
    lappend S "        while (i < n) : (i += 1) {"
    lappend S "            const f = a\[i*n+k\] / pv; if (f == 0) continue;"
    lappend S "            var c: usize = k;"
    lappend S "            while (c < n) : (c += 1) { a\[i*n+c\] -= f * a\[k*n+c\]; }"
    lappend S "            z\[i\] -= f * z\[k\];"
    lappend S "        }"
    lappend S "    }"
    lappend S "    var ii: usize = n;"
    lappend S "    while (ii > 0) { ii -= 1; var s = z\[ii\]; var c: usize = ii + 1;"
    lappend S "        while (c < n) : (c += 1) { s -= a\[ii*n+c\] * z\[c\]; } z\[ii\] = s / a\[ii*n+ii\]; }"
    lappend S "}"
    lappend S ""
    lappend S "fn assemble(a: \[\]f64, z: \[\]f64) void {"
    lappend S "    for (a) |*x| x.* = 0;"
    lappend S "    for (z) |*x| x.* = 0;"
    lappend S "    { var i: usize = 0; while (i < N) : (i += 1) a\[i*SZ+i\] += 1e-12; }"
    foreach line $base { lappend S $line }
    if {$NR} {
        lappend S "    { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "        if (energized\[r\]) stampG(a, r_com\[r\], r_no\[r\], 1.0 / RSMALL)"
        lappend S "        else stampG(a, r_com\[r\], r_nc\[r\], 1.0 / RSMALL);"
        lappend S "    } }"
    }
    if {$ND} {
        lappend S "    { var d: usize = 0; while (d < ND) : (d += 1) {"
        lappend S "        const c = diodeComp(d, diodeV\[d\]);"
        lappend S "        stampG(a, d_a\[d\], d_k\[d\], c.gt);"
        lappend S "        if (d_a\[d\] != 0) z\[d_a\[d\]-1\] -= c.ieq;"
        lappend S "        if (d_k\[d\] != 0) z\[d_k\[d\]-1\] += c.ieq;"
        lappend S "    } }"
    }
    lappend S "}"
    lappend S ""
    lappend S "pub fn main() !void {"
    lappend S "    const stdout = std.io.getStdOut().writer();"
    lappend S "    var a = \[_\]f64{0} ** (SZ * SZ);"
    lappend S "    var z = \[_\]f64{0} ** SZ;"
    lappend S "    var outer: usize = 0;"
    lappend S "    while (outer < 200) : (outer += 1) {"
    lappend S "        var newton: usize = 0;"
    lappend S "        while (newton < 100) : (newton += 1) {"
    lappend S "            assemble(a\[0..\], z\[0..\]);"
    lappend S "            solve(a\[0..\], z\[0..\], SZ);"
    if {$ND} {
        lappend S "            var maxd: f64 = 0;"
        lappend S "            var d: usize = 0;"
        lappend S "            while (d < ND) : (d += 1) {"
        lappend S "                const vd = nv(z\[0..\], d_a\[d\]) - nv(z\[0..\], d_k\[d\]);"
        lappend S "                var vnew = vd;"
        lappend S "                if (d_rs\[d\] > 0) { const c = diodeComp(d, diodeV\[d\]); vnew = vd - (c.gt*vd + c.ieq)*d_rs\[d\]; }"
        lappend S "                if (vnew - diodeV\[d\] > 0.5) vnew = diodeV\[d\] + 0.5;"
        lappend S "                if (diodeV\[d\] - vnew > 0.5) vnew = diodeV\[d\] - 0.5;"
        lappend S "                const dd = @abs(vnew - diodeV\[d\]); if (dd > maxd) maxd = dd;"
        lappend S "                diodeV\[d\] = vnew;"
        lappend S "            }"
        lappend S "            if (maxd < 1e-9) break;"
    } else {
        lappend S "            break;"
    }
    lappend S "        }"
    if {$NR || $NP} {
        lappend S "        var changed = false;"
        if {$NR} {
            lappend S "        { var r: usize = 0; while (r < NR) : (r += 1) {"
            lappend S "            const ic = @abs(nv(z\[0..\], r_c1\[r\]) - nv(z\[0..\], r_c2\[r\])) / r_rc\[r\];"
            lappend S "            const was = energized\[r\];"
            lappend S "            const now = if (was) (ic >= r_do\[r\]) else (ic >= r_pu\[r\]);"
            lappend S "            if (now != was) { energized\[r\] = now; changed = true; }"
            lappend S "        } }"
        }
        if {$NP} {
            # protective devices blow/trip on over-rating current (instant at DC)
            lappend S "        { var p: usize = 0; while (p < NP) : (p += 1) {"
            lappend S "            if (!fb_open\[p\] and @abs(z\[fb_row\[p\]\]) > fb_rating\[p\]) { fb_open\[p\] = true; changed = true; }"
            lappend S "        } }"
        }
        lappend S "        if (!changed) break;"
    } else {
        lappend S "        break;"
    }
    lappend S "    }"
    lappend S "    try stdout.print(\"DC operating point of \\\"$name\\\" (ground = 0 V)\\n\", .{});"
    foreach line $prints { lappend S $line }
    lappend S "}"
    return [join $S \n]
}

# ====================================================================
#  Zig transient backend -- emit a time-stepping solver.
# ====================================================================
#
# Steps the circuit forward in fixed dt with backward-Euler companion models
# (capacitors, inductors, and inductive relay coils), Newton for diodes each
# step, and relays switching with a one-step lag plus their propagation delay
# and hysteresis -- exactly the engine's transient analyser.  It prints a
# table of node voltages over time.  (Transformers in transient, the i2t
# trip curve and timed -events stimulus are not emitted yet; the IR carries
# their data for when they are.)
proc ::schem::backend::ZigTran {cir duration dt {events {}}} {
    variable ::schem::RSMALL
    set N [dict get $cir nodes count]
    set nsteps [expr {int(ceil($duration/$dt))}]

    # Transient lowering: caps/inductors/inductive-coils are companion
    # conductances (not branches); branches are sources/meters/protection/
    # ideal wires only.
    set conds {} ; set branches {} ; set relays {} ; set diodes {}
    set caps {} ; set inds {} ; set coils {}
    set switches {} ; set swidx [dict create]   ;# runtime switch state for -events
    set protect {}                                ;# fuses/breakers that can trip
    foreach e [dict get $cir elements] {
        set nm [dict get $e name]
        if {[dict exists $e nodes]} { set nd [dict get $e nodes] }
        switch [dict get $e class] {
            conductance { lappend conds [list [dict get $nd a] [dict get $nd b] [dict get $e g] $nm] }
            source      { lappend branches [list [dict get $nd pos] [dict get $nd neg] [dict get $e emf] [dict get $e rs] $nm] }
            switch {
                dict set swidx $nm [llength $switches]
                lappend switches [list [dict get $nd a] [dict get $nd b] [dict get $e r_closed] \
                    [expr {[dict get $e state] in {closed pressed} ? "true" : "false"}]]
            }
            meter       { lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm] }
            protective  { if {[dict get $e state] in {intact closed}} { lappend protect [list [llength $branches] [dict get $e rating] [dict get $e i2t] $nm] ; lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm] } }
            conductor   { set r [dict get $e r] ; if {$r > 0} { lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/$r}] $nm] } else { lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm] } }
            nonlinear   { set m [dict get $e model] ; lappend diodes [list [dict get $nd a] [dict get $nd k] [dict get $m is] [dict get $m n] [dict get $m rs] [dict get $m bv] $nm] }
            reactive {
                if {[dict get $e type] eq "capacitor"} {
                    lappend caps [list [dict get $nd a] [dict get $nd b] [dict get $e c] [dict get $e esr] [dict get $e rleak] [dict get $e v0]]
                } else {
                    lappend inds [list [dict get $nd a] [dict get $nd b] [dict get $e l] [dict get $e r] [dict get $e i0]]
                }
            }
            relay {
                set cn [dict get $e coil nodes] ; set kn [dict get $e contact nodes]
                set cL [dict get $e coil l]
                if {$cL > 0} {
                    lappend coils [list [dict get $cn c1] [dict get $cn c2] [dict get $e coil r] $cL]
                    set ci [expr {[llength $coils]-1}]
                } else {
                    lappend conds [list [dict get $cn c1] [dict get $cn c2] [dict get $e coil g] $nm.coil]
                    set ci -1
                }
                lappend relays [list [dict get $cn c1] [dict get $cn c2] [dict get $e coil r] \
                    [dict get $e pickup] [dict get $e dropout] [dict get $e delay] \
                    [dict get $kn com] [dict get $kn no] [dict get $kn nc] $ci $nm]
            }
            coupled { return -code error "zig transient does not yet support transformers ([dict get $e name])" }
        }
    }
    set SZ [expr {$N + [llength $branches]}]
    set NR [llength $relays] ; set ND [llength $diodes]
    set NC [llength $caps] ; set NL [llength $inds] ; set NK [llength $coils]
    set NS [llength $switches] ; set NP [llength $protect]
    set b2p [dict create] ; set pj 0
    foreach p $protect { dict set b2p [lindex $p 0] $pj ; incr pj }
    # compile the -events stimulus into {step swIndex newState} actions
    set actions {}
    foreach {t op} $events {
        lassign $op verb swname
        if {![dict exists $swidx $swname]} continue
        set st [expr {int(ceil(($t - 1e-12)/$dt))}]
        set b [expr {$verb in {close press} ? "true" : "false"}]
        lappend actions [list $st [dict get $swidx $swname] $b $verb $swname]
    }
    set name [dict get $cir name]

    proc A2 {ty vals} { return "\[[llength $vals]\]$ty{[join $vals {, }]}" }

    set S {}
    lappend S "// Generated by Schem -- TRANSIENT analysis of \"$name\""
    lappend S "// Derived from the Circuit IR; the .schem schematic is the source."
    lappend S "// $N node(s); dt=[Zf $dt] s, $nsteps steps.  Build: zig run this.zig"
    lappend S "const std = @import(\"std\");"
    lappend S "const N: usize = $N;"
    lappend S "const SZ: usize = $SZ;"
    lappend S "const DT: f64 = [Zf $dt];"
    lappend S "const NSTEPS: usize = $nsteps;"
    lappend S "const RSMALL: f64 = [Zf $RSMALL];"
    lappend S "const NR: usize = $NR; const ND: usize = $ND; const NC: usize = $NC; const NL: usize = $NL; const NK: usize = $NK; const NS: usize = $NS; const NP: usize = $NP;"
    lappend S ""
    # protective devices (fuses/breakers) that can trip during the run
    if {$NP} {
        set fb_row {} ; set fb_rating {} ; set fb_i2t {}
        foreach p $protect { lappend fb_row [expr {$N + [lindex $p 0]}] ; lappend fb_rating [Zf [lindex $p 1]] ; lappend fb_i2t [Zf [lindex $p 2]] }
        lappend S "const fb_row = [A2 usize $fb_row]; const fb_rating = [A2 f64 $fb_rating]; const fb_i2t = [A2 f64 $fb_i2t];"
        lappend S "var fb_open = \[_\]bool{false} ** NP;"
        lappend S "var fb_heat = \[_\]f64{0} ** NP;"
    }
    # switch state (driven by -events)
    if {$NS} {
        set s_a {} ; set s_b {} ; set s_rc {} ; set s_init {}
        foreach sw $switches { lassign $sw a b rc init ; lappend s_a $a ; lappend s_b $b ; lappend s_rc [Zf $rc] ; lappend s_init $init }
        lappend S "const s_a = [A2 usize $s_a]; const s_b = [A2 usize $s_b]; const s_rc = [A2 f64 $s_rc];"
        lappend S "var sw_state = \[NS\]bool{[join $s_init {, }]};"
    }
    # diode metadata
    if {$ND} {
        set d_a {} ; set d_k {} ; set d_is {} ; set d_n {} ; set d_rs {} ; set d_bv {}
        foreach d $diodes { lassign $d na nk is nf rs bv nm ; lappend d_a $na ; lappend d_k $nk ; lappend d_is [Zf $is] ; lappend d_n [Zf $nf] ; lappend d_rs [Zf $rs] ; lappend d_bv [Zf $bv] }
        lappend S "const d_a = [A2 usize $d_a]; const d_k = [A2 usize $d_k];"
        lappend S "const d_is = [A2 f64 $d_is]; const d_n = [A2 f64 $d_n]; const d_rs = [A2 f64 $d_rs]; const d_bv = [A2 f64 $d_bv];"
        lappend S "var diodeV = \[_\]f64{0} ** ND;"
    }
    # capacitor metadata + state
    if {$NC} {
        set c_a {} ; set c_b {} ; set c_C {} ; set c_esr {} ; set c_rl {} ; set c_v0 {}
        foreach c $caps { lassign $c na nb C esr rl v0 ; lappend c_a $na ; lappend c_b $nb ; lappend c_C [Zf $C] ; lappend c_esr [Zf $esr] ; lappend c_rl [Zf $rl] ; lappend c_v0 [Zf $v0] }
        lappend S "const c_a = [A2 usize $c_a]; const c_b = [A2 usize $c_b];"
        lappend S "const c_C = [A2 f64 $c_C]; const c_esr = [A2 f64 $c_esr]; const c_rl = [A2 f64 $c_rl];"
        lappend S "const c_v0 = [A2 f64 $c_v0]; var capVc = c_v0;"
    }
    # inductor metadata + state
    if {$NL} {
        set i_a {} ; set i_b {} ; set i_L {} ; set i_r {} ; set i_i0 {}
        foreach c $inds { lassign $c na nb L r i0 ; lappend i_a $na ; lappend i_b $nb ; lappend i_L [Zf $L] ; lappend i_r [Zf $r] ; lappend i_i0 [Zf $i0] }
        lappend S "const i_a = [A2 usize $i_a]; const i_b = [A2 usize $i_b];"
        lappend S "const i_L = [A2 f64 $i_L]; const i_r = [A2 f64 $i_r];"
        lappend S "const i_i0 = [A2 f64 $i_i0]; var indI = i_i0;"
    }
    # inductive coil metadata + state
    if {$NK} {
        set k_c1 {} ; set k_c2 {} ; set k_r {} ; set k_L {}
        foreach c $coils { lassign $c c1 c2 r L ; lappend k_c1 $c1 ; lappend k_c2 $c2 ; lappend k_r [Zf $r] ; lappend k_L [Zf $L] }
        lappend S "const k_c1 = [A2 usize $k_c1]; const k_c2 = [A2 usize $k_c2]; const k_r = [A2 f64 $k_r]; const k_L = [A2 f64 $k_L];"
        lappend S "var coilI = \[_\]f64{0} ** NK;"
    }
    # relay metadata + state
    if {$NR} {
        set r_c1 {} ; set r_c2 {} ; set r_rc {} ; set r_pu {} ; set r_do {} ; set r_dl {}
        set r_com {} ; set r_no {} ; set r_nc {} ; set r_ci {}
        foreach r $relays { lassign $r c1 c2 rc pu do dl com no nc ci nm
            lappend r_c1 $c1 ; lappend r_c2 $c2 ; lappend r_rc [Zf $rc] ; lappend r_pu [Zf $pu]
            lappend r_do [Zf $do] ; lappend r_dl [Zf $dl] ; lappend r_com $com ; lappend r_no $no ; lappend r_nc $nc ; lappend r_ci $ci }
        lappend S "const r_c1 = [A2 usize $r_c1]; const r_c2 = [A2 usize $r_c2]; const r_rc = [A2 f64 $r_rc];"
        lappend S "const r_pu = [A2 f64 $r_pu]; const r_do = [A2 f64 $r_do]; const r_dl = [A2 f64 $r_dl];"
        lappend S "const r_com = [A2 usize $r_com]; const r_no = [A2 usize $r_no]; const r_nc = [A2 usize $r_nc];"
        lappend S "const r_ci = [A2 i64 $r_ci];"
        lappend S "var energized = \[_\]bool{false} ** NR;"
        lappend S "var pend_t = \[_\]bool{false} ** NR;   // pending target"
        lappend S "var pend_s = \[_\]f64{0} ** NR;        // time the pending move began"
    }
    lappend S ""
    # --- helpers (shared with the DC backend) ---
    lappend S "fn nv(z: \[\]const f64, nid: usize) f64 { return if (nid == 0) 0.0 else z\[nid - 1\]; }"
    lappend S "fn stampG(a: \[\]f64, na: usize, nb: usize, g: f64) void {"
    lappend S "    if (na != 0) a\[(na-1)*SZ+(na-1)\] += g;"
    lappend S "    if (nb != 0) a\[(nb-1)*SZ+(nb-1)\] += g;"
    lappend S "    if (na != 0 and nb != 0) { a\[(na-1)*SZ+(nb-1)\] -= g; a\[(nb-1)*SZ+(na-1)\] -= g; }"
    lappend S "}"
    lappend S "fn stampI(z: \[\]f64, na: usize, nb: usize, i: f64) void {"
    lappend S "    if (na != 0) z\[na-1\] -= i;"
    lappend S "    if (nb != 0) z\[nb-1\] += i;"
    lappend S "}"
    lappend S "fn stampBranch(a: \[\]f64, z: \[\]f64, row: usize, p: usize, q: usize, emf: f64, rs: f64) void {"
    lappend S "    if (p != 0) { a\[(p-1)*SZ+row\] += 1.0; a\[row*SZ+(p-1)\] += 1.0; }"
    lappend S "    if (q != 0) { a\[(q-1)*SZ+row\] -= 1.0; a\[row*SZ+(q-1)\] -= 1.0; }"
    lappend S "    if (rs != 0) a\[row*SZ+row\] -= rs;"
    lappend S "    z\[row\] = emf;"
    lappend S "}"
    if {$ND} {
        lappend S "const DG = struct { gt: f64, ieq: f64 };"
        lappend S "fn diodeComp(d: usize, vj: f64) DG {"
        lappend S "    const Vt = 0.025852 * d_n\[d\];"
        lappend S "    const ef = @exp(@min(vj / Vt, 80.0));"
        lappend S "    var Id = d_is\[d\] * (ef - 1.0); var gj = d_is\[d\] * ef / Vt;"
        lappend S "    if (d_bv\[d\] > 0 and vj < -d_bv\[d\]) { const eb = @exp(@min((-vj - d_bv\[d\]) / Vt, 80.0)); Id -= d_is\[d\]*(eb-1.0); gj += d_is\[d\]*eb/Vt; }"
        lappend S "    if (gj < 1e-12) gj = 1e-12;"
        lappend S "    const gt = gj / (1.0 + gj * d_rs\[d\]);"
        lappend S "    return .{ .gt = gt, .ieq = Id - gt * (vj + Id * d_rs\[d\]) };"
        lappend S "}"
    }
    # solve (same as DC)
    lappend S "fn solve(a: \[\]f64, z: \[\]f64, n: usize) void {"
    lappend S "    var k: usize = 0;"
    lappend S "    while (k < n) : (k += 1) {"
    lappend S "        var piv = k; var best = @abs(a\[k*n+k\]); var i = k + 1;"
    lappend S "        while (i < n) : (i += 1) { const v = @abs(a\[i*n+k\]); if (v > best) { best = v; piv = i; } }"
    lappend S "        if (piv != k) { var c: usize = 0; while (c < n) : (c += 1) { const t = a\[k*n+c\]; a\[k*n+c\] = a\[piv*n+c\]; a\[piv*n+c\] = t; } const tz = z\[k\]; z\[k\] = z\[piv\]; z\[piv\] = tz; }"
    lappend S "        const pv = a\[k*n+k\]; i = k + 1;"
    lappend S "        while (i < n) : (i += 1) { const f = a\[i*n+k\] / pv; if (f == 0) continue; var c: usize = k; while (c < n) : (c += 1) { a\[i*n+c\] -= f * a\[k*n+c\]; } z\[i\] -= f * z\[k\]; }"
    lappend S "    }"
    lappend S "    var ii: usize = n;"
    lappend S "    while (ii > 0) { ii -= 1; var s = z\[ii\]; var c: usize = ii + 1; while (c < n) : (c += 1) { s -= a\[ii*n+c\] * z\[c\]; } z\[ii\] = s / a\[ii*n+ii\]; }"
    lappend S "}"
    lappend S ""
    # --- assemble (companions from current state) ---
    lappend S "fn assemble(a: \[\]f64, z: \[\]f64) void {"
    lappend S "    for (a) |*x| x.* = 0; for (z) |*x| x.* = 0;"
    lappend S "    { var i: usize = 0; while (i < N) : (i += 1) a\[i*SZ+i\] += 1e-12; }"
    foreach c $conds { lassign $c na nb g nm ; lappend S "    stampG(a, $na, $nb, [Zf $g]); // $nm" }
    set k 0
    foreach br $branches {
        lassign $br p q emf rs nm
        set row [expr {$N+$k}]
        if {[dict exists $b2p $k]} {
            lappend S "    if (fb_open\[[dict get $b2p $k]\]) { a\[$row*SZ+$row\] += 1.0; z\[$row\] = 0.0; } else stampBranch(a, z, $row, $p, $q, [Zf $emf], [Zf $rs]); // $nm"
        } else {
            lappend S "    stampBranch(a, z, $row, $p, $q, [Zf $emf], [Zf $rs]); // $nm"
        }
        incr k
    }
    if {$NS} {
        lappend S "    { var w: usize = 0; while (w < NS) : (w += 1) { if (sw_state\[w\]) stampG(a, s_a\[w\], s_b\[w\], 1.0 / s_rc\[w\]); } }"
    }
    if {$NC} {
        lappend S "    { var c: usize = 0; while (c < NC) : (c += 1) {"
        lappend S "        if (c_rl\[c\] > 0) stampG(a, c_a\[c\], c_b\[c\], 1.0 / c_rl\[c\]);"
        lappend S "        const geq = 1.0 / (c_esr\[c\] + DT / c_C\[c\]);"
        lappend S "        stampG(a, c_a\[c\], c_b\[c\], geq);"
        lappend S "        stampI(z, c_a\[c\], c_b\[c\], -geq * capVc\[c\]);"
        lappend S "    } }"
    }
    if {$NL} {
        lappend S "    { var c: usize = 0; while (c < NL) : (c += 1) {"
        lappend S "        const geq = DT / (i_r\[c\]*DT + i_L\[c\]);"
        lappend S "        stampG(a, i_a\[c\], i_b\[c\], geq);"
        lappend S "        stampI(z, i_a\[c\], i_b\[c\], geq * (i_L\[c\]/DT) * indI\[c\]);"
        lappend S "    } }"
    }
    if {$NK} {
        lappend S "    { var c: usize = 0; while (c < NK) : (c += 1) {"
        lappend S "        const geq = DT / (k_r\[c\]*DT + k_L\[c\]);"
        lappend S "        stampG(a, k_c1\[c\], k_c2\[c\], geq);"
        lappend S "        stampI(z, k_c1\[c\], k_c2\[c\], geq * (k_L\[c\]/DT) * coilI\[c\]);"
        lappend S "    } }"
    }
    if {$NR} {
        lappend S "    { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "        if (energized\[r\]) stampG(a, r_com\[r\], r_no\[r\], 1.0/RSMALL) else stampG(a, r_com\[r\], r_nc\[r\], 1.0/RSMALL);"
        lappend S "    } }"
    }
    if {$ND} {
        lappend S "    { var d: usize = 0; while (d < ND) : (d += 1) { const cc = diodeComp(d, diodeV\[d\]); stampG(a, d_a\[d\], d_k\[d\], cc.gt); stampI(z, d_a\[d\], d_k\[d\], cc.ieq); } }"
    }
    lappend S "}"
    lappend S ""
    # --- main: time loop ---
    lappend S "pub fn main() !void {"
    lappend S "    const stdout = std.io.getStdOut().writer();"
    lappend S "    var a = \[_\]f64{0} ** (SZ * SZ);"
    lappend S "    var z = \[_\]f64{0} ** SZ;"
    lappend S "    try stdout.print(\"transient \\\"$name\\\"  (t, then N1..N$N)\\n\", .{});"
    lappend S "    var step: usize = 0;"
    lappend S "    while (step <= NSTEPS) : (step += 1) {"
    lappend S "        const tnow = @as(f64, @floatFromInt(step)) * DT;"
    if {[llength $actions]} {
        lappend S "        // timed stimulus (-events): operate contacts on schedule"
        foreach act [lsort -integer -index 0 $actions] {
            lassign $act st si b verb swname
            lappend S "        if (step == $st) sw_state\[$si\] = $b; // $verb $swname"
        }
    }
    lappend S "        // Newton (diodes) at this step; relay state is from the previous step."
    lappend S "        var newton: usize = 0;"
    lappend S "        while (newton < 100) : (newton += 1) {"
    lappend S "            assemble(a\[0..\], z\[0..\]); solve(a\[0..\], z\[0..\], SZ);"
    if {$ND} {
        lappend S "            var maxd: f64 = 0; var d: usize = 0;"
        lappend S "            while (d < ND) : (d += 1) {"
        lappend S "                const vd = nv(z\[0..\], d_a\[d\]) - nv(z\[0..\], d_k\[d\]);"
        lappend S "                var vnew = vd;"
        lappend S "                if (d_rs\[d\] > 0) { const cc = diodeComp(d, diodeV\[d\]); vnew = vd - (cc.gt*vd + cc.ieq)*d_rs\[d\]; }"
        lappend S "                if (vnew - diodeV\[d\] > 0.5) vnew = diodeV\[d\] + 0.5;"
        lappend S "                if (diodeV\[d\] - vnew > 0.5) vnew = diodeV\[d\] - 0.5;"
        lappend S "                const dd = @abs(vnew - diodeV\[d\]); if (dd > maxd) maxd = dd; diodeV\[d\] = vnew;"
        lappend S "            }"
        lappend S "            if (maxd < 1e-9) break;"
    } else {
        lappend S "            break;"
    }
    lappend S "        }"
    # record
    lappend S "        try stdout.print(\"{d:.5}\", .{tnow});"
    for {set i 1} {$i <= $N} {incr i} {
        lappend S "        try stdout.print(\" {d:.4}\", .{ z\[[expr {$i-1}]\] });"
    }
    lappend S "        try stdout.print(\"\\n\", .{});"
    # advance reactive state
    if {$NC} {
        lappend S "        { var c: usize = 0; while (c < NC) : (c += 1) {"
        lappend S "            const geq = 1.0 / (c_esr\[c\] + DT / c_C\[c\]);"
        lappend S "            const vab = nv(z\[0..\], c_a\[c\]) - nv(z\[0..\], c_b\[c\]);"
        lappend S "            const cur = geq*vab - geq*capVc\[c\];"
        lappend S "            capVc\[c\] += (DT / c_C\[c\]) * cur;"
        lappend S "        } }"
    }
    if {$NL} {
        lappend S "        { var c: usize = 0; while (c < NL) : (c += 1) {"
        lappend S "            const geq = DT / (i_r\[c\]*DT + i_L\[c\]);"
        lappend S "            const vab = nv(z\[0..\], i_a\[c\]) - nv(z\[0..\], i_b\[c\]);"
        lappend S "            indI\[c\] = geq*vab + geq*(i_L\[c\]/DT)*indI\[c\];"
        lappend S "        } }"
    }
    if {$NK} {
        lappend S "        { var c: usize = 0; while (c < NK) : (c += 1) {"
        lappend S "            const geq = DT / (k_r\[c\]*DT + k_L\[c\]);"
        lappend S "            const vab = nv(z\[0..\], k_c1\[c\]) - nv(z\[0..\], k_c2\[c\]);"
        lappend S "            coilI\[c\] = geq*vab + geq*(k_L\[c\]/DT)*coilI\[c\];"
        lappend S "        } }"
    }
    # decide next-step relay state (one-dt lag + delay + hysteresis)
    if {$NR} {
        lappend S "        { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "            var ic: f64 = undefined;"
        if {$NK} {
            lappend S "            if (r_ci\[r\] >= 0) { ic = @abs(coilI\[@intCast(r_ci\[r\])\]); }"
            lappend S "            else { ic = @abs(nv(z\[0..\], r_c1\[r\]) - nv(z\[0..\], r_c2\[r\])) / r_rc\[r\]; }"
        } else {
            lappend S "            ic = @abs(nv(z\[0..\], r_c1\[r\]) - nv(z\[0..\], r_c2\[r\])) / r_rc\[r\];"
        }
        lappend S "            const was = energized\[r\];"
        lappend S "            const now = if (was) (ic >= r_do\[r\]) else (ic >= r_pu\[r\]);"
        lappend S "            if (now == was) { pend_t\[r\] = was; }"
        lappend S "            else if (r_dl\[r\] <= 0) { energized\[r\] = now; }"
        lappend S "            else {"
        lappend S "                if (pend_t\[r\] != now) { pend_t\[r\] = now; pend_s\[r\] = tnow; }"
        lappend S "                if (tnow - pend_s\[r\] >= r_dl\[r\]) energized\[r\] = now;"
        lappend S "            }"
        lappend S "        } }"
    }
    # protective tripping: a fuse blows / breaker trips on over-rating current.
    # i2t == 0 -> instantaneous; i2t > 0 -> inverse time-current (heat builds as
    # (I^2 - rating^2)*dt, cools below rating, trips when it exceeds i2t).
    if {$NP} {
        lappend S "        { var p: usize = 0; while (p < NP) : (p += 1) {"
        lappend S "            if (fb_open\[p\]) continue;"
        lappend S "            const ip = @abs(z\[fb_row\[p\]\]);"
        lappend S "            if (fb_i2t\[p\] <= 0) { if (ip > fb_rating\[p\]) fb_open\[p\] = true; }"
        lappend S "            else {"
        lappend S "                if (ip > fb_rating\[p\]) fb_heat\[p\] += (ip*ip - fb_rating\[p\]*fb_rating\[p\]) * DT"
        lappend S "                else fb_heat\[p\] = @max(0.0, fb_heat\[p\] - fb_rating\[p\]*fb_rating\[p\]*DT);"
        lappend S "                if (fb_heat\[p\] >= fb_i2t\[p\]) fb_open\[p\] = true;"
        lappend S "            }"
        lappend S "        } }"
    }
    lappend S "    }"
    lappend S "}"
    return [join $S \n]
}

# ====================================================================
#  digref -- the DIGITAL reference backend (boolean cycle evaluation).
# ====================================================================
#
# The counterpart to dcref: where dcref/zig (literal mode) solve the real
# electrical circuit by MNA, digref evaluates a *provably-digital* relay-logic
# circuit as booleans -- a net is HIGH iff a closed-contact path connects it to
# a supply rail, else LOW (the pull-down default), with relays switching on a
# fixed point.  For a digital circuit this gives the IDENTICAL HIGH/LOW result
# as the electrical solve, at O(nets+contacts) per pass instead of an O(n^3)
# matrix factorisation.  It is the spec the `zig -digital` emitter transcribes,
# and it is verified against the electrical engine.
#
# Returns a dict node-id -> 1 (HIGH) / 0 (LOW).  Refuses non-digital parts
# (diodes, reactives, transformers) -- use literal mode for those.
proc ::schem::backend::digref {cir} {
    set N [dict get $cir nodes count]
    set vcc {} ; set static {} ; set relays {} ; set unsupported {}
    foreach e [dict get $cir elements] {
        set nm [dict get $e name]
        if {[dict exists $e nodes]} { set nd [dict get $e nodes] }
        switch [dict get $e class] {
            source {
                if {[dict get $nd neg] == 0} { lappend vcc [dict get $nd pos] } \
                else { lappend unsupported "$nm (supply not referenced to ground)" }
            }
            switch    { if {[dict get $e state] in {closed pressed}} { lappend static [list [dict get $nd a] [dict get $nd b]] } }
            conductance { }
            relay {
                set cn [dict get $e coil nodes] ; set kn [dict get $e contact nodes]
                lappend relays [list [dict get $cn c1] [dict get $cn c2] [dict get $kn com] [dict get $kn no] [dict get $kn nc]]
            }
            meter      { lappend static [list [dict get $nd a] [dict get $nd b]] }
            protective { if {[dict get $e state] in {intact closed}} { lappend static [list [dict get $nd a] [dict get $nd b]] } }
            conductor  { lappend static [list [dict get $nd a] [dict get $nd b]] }
            default    { lappend unsupported "$nm ([dict get $e type])" }
        }
    }
    if {[llength $unsupported]} {
        return -code error "digital mode needs a relay-logic circuit; not digital: [join $unsupported {, }]"
    }
    set energized [dict create]
    for {set iter 0} {$iter < 1000} {incr iter} {
        # closed-edge adjacency for this relay state
        array unset adj ; array set adj {}
        foreach e $static {
            lappend adj([lindex $e 0]) [lindex $e 1] ; lappend adj([lindex $e 1]) [lindex $e 0]
        }
        set ri 0
        foreach r $relays {
            lassign $r c1 c2 com no nc
            set t [expr {[dict exists $energized $ri] ? $no : $nc}]
            lappend adj($com) $t ; lappend adj($t) $com
            incr ri
        }
        # HIGH = reachable from any supply rail through closed contacts.
        array unset high ; array set high {}
        set queue {}
        foreach v $vcc { if {![info exists high($v)]} { set high($v) 1 ; lappend queue $v } }
        while {[llength $queue]} {
            set cur [lindex $queue 0] ; set queue [lrange $queue 1 end]
            foreach nb [expr {[info exists adj($cur)] ? $adj($cur) : {}}] {
                if {![info exists high($nb)]} { set high($nb) 1 ; lappend queue $nb }
            }
        }
        if {[info exists high(0)]} { unset high(0) }   ;# ground is never HIGH
        # a coil is energised when it spans a HIGH-to-LOW differential
        set newen [dict create] ; set ri 0
        foreach r $relays {
            lassign $r c1 c2 com no nc
            if {[info exists high($c1)] != [info exists high($c2)]} { dict set newen $ri 1 }
            incr ri
        }
        if {$newen eq $energized} break
        set energized $newen
    }
    set v [dict create 0 0]
    for {set i 1} {$i <= $N} {incr i} { dict set v $i [expr {[info exists high($i)] ? 1 : 0}] }
    return $v
}
