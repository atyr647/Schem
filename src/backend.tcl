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
    set conds {} ; set branches {} ; set relays {} ; set diodes {}
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
        conds $conds branches $branches relays $relays diodes $diodes]
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
    set gc [expr {1.0/$RSMALL}]

    set energized [lrepeat [llength $relays] 0]
    set diodeV    [lrepeat [llength $diodes] 0.0]
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
                if {$p != 0} { ::schem::la::spacc A [expr {$p-1}] $row 1.0 ; ::schem::la::spacc A $row [expr {$p-1}] 1.0 }
                if {$q != 0} { ::schem::la::spacc A [expr {$q-1}] $row -1.0 ; ::schem::la::spacc A $row [expr {$q-1}] -1.0 }
                if {$rs != 0} { ::schem::la::spacc A $row $row [expr {-$rs}] }
                lset z $row $emf
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
proc ::schem::backend::zig {cir} {
    variable ::schem::RSMALL
    set L [LowerDC $cir]
    set N [dict get $L n] ; set SZ [dict get $L sz]
    set conds [dict get $L conds] ; set branches [dict get $L branches]
    set relays [dict get $L relays] ; set diodes [dict get $L diodes]
    set NR [llength $relays] ; set ND [llength $diodes]
    set name [dict get $cir name]

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
        lappend base "    stampBranch(a, z, [expr {$N+$k}], $p, $q, [Zf $emf], [Zf $rs]); // $nm"
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
    lappend S "const RSMALL: f64 = [Zf $RSMALL];"
    lappend S ""
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
    lappend S "var a: \[SZ * SZ\]f64 = undefined;"
    lappend S "var z: \[SZ\]f64 = undefined;"
    lappend S ""
    lappend S "fn assemble() void {"
    lappend S "    for (&a) |*x| x.* = 0;"
    lappend S "    for (&z) |*x| x.* = 0;"
    lappend S "    { var i: usize = 0; while (i < N) : (i += 1) a\[i*SZ+i\] += 1e-12; }"
    foreach line $base { lappend S $line }
    if {$NR} {
        lappend S "    { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "        if (energized\[r\]) stampG(&a, r_com\[r\], r_no\[r\], 1.0 / RSMALL)"
        lappend S "        else stampG(&a, r_com\[r\], r_nc\[r\], 1.0 / RSMALL);"
        lappend S "    } }"
    }
    if {$ND} {
        lappend S "    { var d: usize = 0; while (d < ND) : (d += 1) {"
        lappend S "        const c = diodeComp(d, diodeV\[d\]);"
        lappend S "        stampG(&a, d_a\[d\], d_k\[d\], c.gt);"
        lappend S "        if (d_a\[d\] != 0) z\[d_a\[d\]-1\] -= c.ieq;"
        lappend S "        if (d_k\[d\] != 0) z\[d_k\[d\]-1\] += c.ieq;"
        lappend S "    } }"
    }
    lappend S "}"
    lappend S ""
    lappend S "pub fn main() !void {"
    lappend S "    const stdout = std.io.getStdOut().writer();"
    lappend S "    var outer: usize = 0;"
    lappend S "    while (outer < 200) : (outer += 1) {"
    lappend S "        var newton: usize = 0;"
    lappend S "        while (newton < 100) : (newton += 1) {"
    lappend S "            assemble();"
    lappend S "            solve(&a, &z, SZ);"
    if {$ND} {
        lappend S "            var maxd: f64 = 0;"
        lappend S "            var d: usize = 0;"
        lappend S "            while (d < ND) : (d += 1) {"
        lappend S "                const vd = nv(&z, d_a\[d\]) - nv(&z, d_k\[d\]);"
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
    if {$NR} {
        lappend S "        var changed = false;"
        lappend S "        var r: usize = 0;"
        lappend S "        while (r < NR) : (r += 1) {"
        lappend S "            const ic = @abs(nv(&z, r_c1\[r\]) - nv(&z, r_c2\[r\])) / r_rc\[r\];"
        lappend S "            const was = energized\[r\];"
        lappend S "            const now = if (was) (ic >= r_do\[r\]) else (ic >= r_pu\[r\]);"
        lappend S "            if (now != was) { energized\[r\] = now; changed = true; }"
        lappend S "        }"
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
