# zig.tcl -- the Zig DC + transient backend (split from backend.tcl).
# Emits a standalone Zig program that solves the board.  Consumes the
# Circuit IR; uses the shared helpers in backend.tcl.

proc ::schem::backend::zig {cir args} {
    # schem::emit $s zig                       -> literal DC operating point (MNA)
    # schem::emit $s zig -transient ...         -> literal transient stepper (MNA)
    # schem::emit $s zig -digital               -> digital boolean cycle evaluator
    # schem::emit $s zig -digital -cycles N ... -> CLOCKED digital (sequential)
    set transient 0 ; set duration 0.01 ; set dt 1e-4 ; set events {} ; set digital 0 ; set cycles 0
    for {set i 0} {$i < [llength $args]} {incr i} {
        switch -- [lindex $args $i] {
            -transient { set transient 1 }
            -digital   { set digital 1 }
            -duration  { set duration [lindex $args [incr i]] }
            -dt        { set dt [lindex $args [incr i]] }
            -cycles    { set cycles [lindex $args [incr i]] }
            -events    { set events [lindex $args [incr i]] }
            default    { return -code error "zig: unknown option [lindex $args $i]" }
        }
    }
    if {$digital} {
        if {$cycles > 0} { return [::schem::backend::ZigDigitalSeq $cir $cycles $events] }
        return [::schem::backend::ZigDigital $cir]
    }
    if {$transient} { return [::schem::backend::ZigTran $cir $duration $dt $events] }
    variable ::schem::RSMALL
    set L [LowerDC $cir]
    if {[llength [dict get $L buffers]]} {
        return -code error "zig (literal DC) does not yet support tri-state buffers; use digital mode (zig -digital) or the dcref reference"
    }
    set N [dict get $L n] ; set SZ [dict get $L sz]
    set conds [dict get $L conds] ; set branches [dict get $L branches]
    set relays [dict get $L relays] ; set diodes [dict get $L diodes]
    set mosfets [dict get $L mosfets] ; set bjts [dict get $L bjts]
    set protect [dict get $L protect]
    set NR [llength $relays] ; set ND [llength $diodes] ; set NM [llength $mosfets] ; set NB [llength $bjts] ; set NP [llength $protect]
    set name [dict get $cir name]
    # map branch index -> protective index (which branches can blow/trip)
    set b2p [dict create] ; set pj 0
    foreach p $protect { dict set b2p [lindex $p 0] $pj ; incr pj }

    # --- metadata arrays for relays, diodes and MOSFETs ---
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
    set m_g {} ; set m_d {} ; set m_s {} ; set m_vto {} ; set m_kp {} ; set m_lambda {} ; set m_pmos {}
    foreach m $mosfets {
        lassign $m ng nd ns vto kp lambda pmos nm
        lappend m_g $ng ; lappend m_d $nd ; lappend m_s $ns
        lappend m_vto [Zf $vto] ; lappend m_kp [Zf $kp] ; lappend m_lambda [Zf $lambda]
        lappend m_pmos [expr {$pmos ? "true" : "false"}]
    }
    set b_b {} ; set b_c {} ; set b_e {} ; set b_is {} ; set b_beta {} ; set b_n {} ; set b_vaf {} ; set b_pnp {}
    foreach b $bjts {
        lassign $b nb nc ne is beta nf vaf pnp nm
        lappend b_b $nb ; lappend b_c $nc ; lappend b_e $ne
        lappend b_is [Zf $is] ; lappend b_beta [Zf $beta] ; lappend b_n [Zf $nf]
        lappend b_vaf [Zf $vaf] ; lappend b_pnp [expr {$pnp ? "true" : "false"}]
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
    lappend S "// $N node(s), $NR relay(s), $ND diode(s), $NM mosfet(s), $NB bjt(s); SZ=$SZ unknowns.  Build: zig run this.zig"
    lappend S "const std = @import(\"std\");"
    lappend S ""
    lappend S "const N: usize = $N;"
    lappend S "const SZ: usize = $SZ;"
    lappend S "const NR: usize = $NR;"
    lappend S "const ND: usize = $ND;"
    lappend S "const NM: usize = $NM;"
    lappend S "const NB: usize = $NB;"
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
    if {$NM} {
        lappend S "const m_g = [Zarr usize $m_g];"
        lappend S "const m_d = [Zarr usize $m_d];"
        lappend S "const m_s = [Zarr usize $m_s];"
        lappend S "const m_vto = [Zarr f64 $m_vto];"
        lappend S "const m_kp = [Zarr f64 $m_kp];"
        lappend S "const m_lambda = [Zarr f64 $m_lambda];"
        lappend S "const m_pmos = [Zarr bool $m_pmos];"
        lappend S "var mosfetVgs = \[_\]f64{0} ** NM;"
        lappend S "var mosfetVds = \[_\]f64{0} ** NM;"
    }
    if {$NB} {
        lappend S "const b_b = [Zarr usize $b_b];"
        lappend S "const b_c = [Zarr usize $b_c];"
        lappend S "const b_e = [Zarr usize $b_e];"
        lappend S "const b_is = [Zarr f64 $b_is];"
        lappend S "const b_beta = [Zarr f64 $b_beta];"
        lappend S "const b_n = [Zarr f64 $b_n];"
        lappend S "const b_vaf = [Zarr f64 $b_vaf];"
        lappend S "const b_pnp = [Zarr bool $b_pnp];"
        lappend S "var bjtVbe = \[_\]f64{0} ** NB;"
        lappend S "var bjtVce = \[_\]f64{0} ** NB;"
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
    if {$NM} {
        lappend S "const MG = struct { id: f64, gm: f64, gds: f64 };"
        lappend S "fn mosfetComp(m: usize, vgs_in: f64, vds_in: f64) MG {"
        lappend S "    const vgs = if (m_pmos\[m\]) -vgs_in else vgs_in;"
        lappend S "    const vds = if (m_pmos\[m\]) -vds_in else vds_in;"
        lappend S "    const vov = vgs - m_vto\[m\];"
        lappend S "    var id: f64 = 0; var gm: f64 = 0; var gds: f64 = 1e-12;"
        lappend S "    if (vov > 0) {"
        lappend S "        if (vds <= 0) {"
        lappend S "            gds = m_kp\[m\] * vov;"
        lappend S "            id = gds * vds;"
        lappend S "        } else if (vds < vov) {"
        lappend S "            const lv = 1.0 + m_lambda\[m\] * vds;"
        lappend S "            id = m_kp\[m\] * (vov*vds - vds*vds*0.5) * lv;"
        lappend S "            gm = m_kp\[m\] * vds * lv;"
        lappend S "            gds = m_kp\[m\]*(vov-vds)*lv + m_kp\[m\]*(vov*vds-vds*vds*0.5)*m_lambda\[m\];"
        lappend S "        } else {"
        lappend S "            const lv = 1.0 + m_lambda\[m\] * vds;"
        lappend S "            id = m_kp\[m\] * 0.5 * vov*vov * lv;"
        lappend S "            gm = m_kp\[m\] * vov * lv;"
        lappend S "            gds = m_kp\[m\] * 0.5 * vov*vov * m_lambda\[m\];"
        lappend S "        }"
        lappend S "    }"
        lappend S "    if (gds < 1e-12) gds = 1e-12;"
        lappend S "    const id_out = if (m_pmos\[m\]) -id else id;"
        lappend S "    return .{ .id = id_out, .gm = gm, .gds = gds };"
        lappend S "}"
    }
    if {$NB} {
        lappend S "const BG = struct { ic: f64, ib: f64, gm: f64, gbe: f64, gce: f64 };"
        lappend S "fn bjtComp(b: usize, vbe_in: f64, vce_in: f64) BG {"
        lappend S "    const vbe = if (b_pnp\[b\]) -vbe_in else vbe_in;"
        lappend S "    const vce = if (b_pnp\[b\]) -vce_in else vce_in;"
        lappend S "    const Vt = 0.025852 * b_n\[b\];"
        lappend S "    const ef = @exp(@min(vbe / Vt, 80.0));"
        lappend S "    const early = if (b_vaf\[b\] > 0) @max(0.01, 1.0 + vce / b_vaf\[b\]) else 1.0;"
        lappend S "    var ic = b_is\[b\] * (ef - 1.0) * early;"
        lappend S "    const gm = @max(b_is\[b\] * ef / Vt * early, 1e-12);"
        lappend S "    const gce: f64 = if (b_vaf\[b\] > 0) @max(b_is\[b\] * (ef - 1.0) / b_vaf\[b\], 1e-12) else 1e-12;"
        lappend S "    var ib = ic / b_beta\[b\];"
        lappend S "    const gbe = @max(gm / b_beta\[b\], 1e-12);"
        lappend S "    if (b_pnp\[b\]) { ic = -ic; ib = -ib; }"
        lappend S "    return .{ .ic = ic, .ib = ib, .gm = gm, .gbe = gbe, .gce = gce };"
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
    if {$NM} {
        lappend S "    { var m: usize = 0; while (m < NM) : (m += 1) {"
        lappend S "        const c = mosfetComp(m, mosfetVgs\[m\], mosfetVds\[m\]);"
        lappend S "        stampG(a, m_d\[m\], m_s\[m\], c.gds);"
        lappend S "        // VCCS: gm*(Vg - Vs) from D to S"
        lappend S "        if (m_d\[m\] != 0 and m_g\[m\] != 0) a\[(m_d\[m\]-1)*SZ+(m_g\[m\]-1)\] += c.gm;"
        lappend S "        if (m_d\[m\] != 0 and m_s\[m\] != 0) a\[(m_d\[m\]-1)*SZ+(m_s\[m\]-1)\] -= c.gm;"
        lappend S "        if (m_s\[m\] != 0 and m_g\[m\] != 0) a\[(m_s\[m\]-1)*SZ+(m_g\[m\]-1)\] -= c.gm;"
        lappend S "        if (m_s\[m\] != 0 and m_s\[m\] != 0) a\[(m_s\[m\]-1)*SZ+(m_s\[m\]-1)\] += c.gm;"
        lappend S "        const ieq = c.id - c.gm*mosfetVgs\[m\] - c.gds*mosfetVds\[m\];"
        lappend S "        if (m_d\[m\] != 0) z\[m_d\[m\]-1\] -= ieq;"
        lappend S "        if (m_s\[m\] != 0) z\[m_s\[m\]-1\] += ieq;"
        lappend S "    } }"
    }
    if {$NB} {
        lappend S "    { var b: usize = 0; while (b < NB) : (b += 1) {"
        lappend S "        const c = bjtComp(b, bjtVbe\[b\], bjtVce\[b\]);"
        lappend S "        // B-E conductance + Norton current"
        lappend S "        stampG(a, b_b\[b\], b_e\[b\], c.gbe);"
        lappend S "        const ibeq = c.ib - c.gbe*bjtVbe\[b\];"
        lappend S "        if (b_b\[b\] != 0) z\[b_b\[b\]-1\] -= ibeq;"
        lappend S "        if (b_e\[b\] != 0) z\[b_e\[b\]-1\] += ibeq;"
        lappend S "        // VCCS: gm*(Vb - Ve) from C to E"
        lappend S "        if (b_c\[b\] != 0 and b_b\[b\] != 0) a\[(b_c\[b\]-1)*SZ+(b_b\[b\]-1)\] += c.gm;"
        lappend S "        if (b_c\[b\] != 0 and b_e\[b\] != 0) a\[(b_c\[b\]-1)*SZ+(b_e\[b\]-1)\] -= c.gm;"
        lappend S "        if (b_e\[b\] != 0 and b_b\[b\] != 0) a\[(b_e\[b\]-1)*SZ+(b_b\[b\]-1)\] -= c.gm;"
        lappend S "        if (b_e\[b\] != 0 and b_e\[b\] != 0) a\[(b_e\[b\]-1)*SZ+(b_e\[b\]-1)\] += c.gm;"
        lappend S "        // C-E conductance + Norton current"
        lappend S "        stampG(a, b_c\[b\], b_e\[b\], c.gce);"
        lappend S "        const iceq = c.ic - c.gm*bjtVbe\[b\] - c.gce*bjtVce\[b\];"
        lappend S "        if (b_c\[b\] != 0) z\[b_c\[b\]-1\] -= iceq;"
        lappend S "        if (b_e\[b\] != 0) z\[b_e\[b\]-1\] += iceq;"
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
    if {$ND || $NM || $NB} {
        lappend S "            var maxd: f64 = 0;"
        if {$ND} {
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
        }
        if {$NM} {
            lappend S "            var m: usize = 0;"
            lappend S "            while (m < NM) : (m += 1) {"
            lappend S "                var vgs = nv(z\[0..\], m_g\[m\]) - nv(z\[0..\], m_s\[m\]);"
            lappend S "                var vds = nv(z\[0..\], m_d\[m\]) - nv(z\[0..\], m_s\[m\]);"
            lappend S "                if (vgs - mosfetVgs\[m\] >  0.5) vgs = mosfetVgs\[m\] + 0.5;"
            lappend S "                if (mosfetVgs\[m\] - vgs >  0.5) vgs = mosfetVgs\[m\] - 0.5;"
            lappend S "                if (vds - mosfetVds\[m\] >  0.5) vds = mosfetVds\[m\] + 0.5;"
            lappend S "                if (mosfetVds\[m\] - vds >  0.5) vds = mosfetVds\[m\] - 0.5;"
            lappend S "                const dv = @max(@abs(vgs-mosfetVgs\[m\]), @abs(vds-mosfetVds\[m\]));"
            lappend S "                if (dv > maxd) maxd = dv;"
            lappend S "                mosfetVgs\[m\] = vgs; mosfetVds\[m\] = vds;"
            lappend S "            }"
        }
        if {$NB} {
            lappend S "            var b: usize = 0;"
            lappend S "            while (b < NB) : (b += 1) {"
            lappend S "                var vbe = nv(z\[0..\], b_b\[b\]) - nv(z\[0..\], b_e\[b\]);"
            lappend S "                var vce = nv(z\[0..\], b_c\[b\]) - nv(z\[0..\], b_e\[b\]);"
            lappend S "                if (vbe - bjtVbe\[b\] >  0.5) vbe = bjtVbe\[b\] + 0.5;"
            lappend S "                if (bjtVbe\[b\] - vbe >  0.5) vbe = bjtVbe\[b\] - 0.5;"
            lappend S "                if (vce - bjtVce\[b\] >  0.5) vce = bjtVce\[b\] + 0.5;"
            lappend S "                if (bjtVce\[b\] - vce >  0.5) vce = bjtVce\[b\] - 0.5;"
            lappend S "                const dv = @max(@abs(vbe-bjtVbe\[b\]), @abs(vce-bjtVce\[b\]));"
            lappend S "                if (dv > maxd) maxd = dv;"
            lappend S "                bjtVbe\[b\] = vbe; bjtVce\[b\] = vce;"
            lappend S "            }"
        }
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
            memory  { return -code error "zig transient does not yet support memory ([dict get $e name]); the engine's run() clocks it -- use the engine for sequential memory" }
            buffer  { return -code error "zig transient does not yet support tri-state buffers ([dict get $e name]); use digital mode (zig -digital) or the engine" }
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

