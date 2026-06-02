# dcref.tcl -- the Tcl reference DC backend (split from backend.tcl).
# An independent MNA solve over the IR, used to verify the engine and
# the Zig backend agree.

proc ::schem::backend::dcref {cir} {
    variable ::schem::RSMALL
    set L [LowerDC $cir]
    set N [dict get $L n] ; set SZ [dict get $L sz]
    if {$SZ == 0} { return [dict create 0 0.0] }
    set conds [dict get $L conds] ; set branches [dict get $L branches]
    set relays [dict get $L relays] ; set diodes [dict get $L diodes]
    set mosfets [dict get $L mosfets]
    set bjts    [dict get $L bjts]
    set protect [dict get $L protect] ; set buffers [dict get $L buffers]
    set gc [expr {1.0/$RSMALL}]
    set b2buf [dict create]   ;# branch index -> {in oe vhigh rout} for tri-state buffers
    foreach buf $buffers { lassign $buf bi in oe vh ro nm ; dict set b2buf $bi [list $in $oe $vh $ro] }

    set energized [lrepeat [llength $relays] 0]
    set diodeV    [lrepeat [llength $diodes] 0.0]
    set mosfetVgs [lrepeat [llength $mosfets] 0.0]
    set mosfetVds [lrepeat [llength $mosfets] 0.0]
    set bjtVbe    [lrepeat [llength $bjts] 0.0]
    set bjtVce    [lrepeat [llength $bjts] 0.0]
    set fbopen    [dict create]   ;# protective branch index -> 1 once tripped
    set bufdrv    [dict create]   ;# buffer branch index -> driven voltage (absent = Hi-Z)
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
            for {set mi 0} {$mi < [llength $mosfets]} {incr mi} {
                lassign [lindex $mosfets $mi] ng nd ns vto kp lambda pmos nm
                lassign [MosfetGI [lindex $mosfetVgs $mi] [lindex $mosfetVds $mi] \
                    $vto $kp $lambda $pmos] Id gm gds
                set vgs0 [lindex $mosfetVgs $mi] ; set vds0 [lindex $mosfetVds $mi]
                set Ieq [expr {$Id - $gm*$vgs0 - $gds*$vds0}]
                StampG A $nd $ns $gds
                # VCCS: gm*(Vg - Vs) from D to S
                foreach {row col s} [list $nd $ng 1 $nd $ns -1 $ns $ng -1 $ns $ns 1] {
                    if {$row != 0 && $col != 0} {
                        ::schem::la::spacc A [expr {$row-1}] [expr {$col-1}] [expr {$s*$gm}]
                    }
                }
                if {$nd != 0} { lset z [expr {$nd-1}] [expr {[lindex $z [expr {$nd-1}]] - $Ieq}] }
                if {$ns != 0} { lset z [expr {$ns-1}] [expr {[lindex $z [expr {$ns-1}]] + $Ieq}] }
            }
            for {set bi 0} {$bi < [llength $bjts]} {incr bi} {
                lassign [lindex $bjts $bi] nb nc ne is beta nf vaf pnp nm
                lassign [BjtGI [lindex $bjtVbe $bi] [lindex $bjtVce $bi] $is $beta $nf $vaf $pnp] Ic Ib gm gbe gce
                set vbe0 [lindex $bjtVbe $bi] ; set vce0 [lindex $bjtVce $bi]
                # B-E conductance + Norton current (base-emitter junction)
                StampG A $nb $ne $gbe
                set Ibeq [expr {$Ib - $gbe*$vbe0}]
                if {$nb != 0} { lset z [expr {$nb-1}] [expr {[lindex $z [expr {$nb-1}]] - $Ibeq}] }
                if {$ne != 0} { lset z [expr {$ne-1}] [expr {[lindex $z [expr {$ne-1}]] + $Ibeq}] }
                # VCCS: gm*(Vb - Ve) from C to E, plus C-E conductance gce
                foreach {row col s} [list $nc $nb 1 $nc $ne -1 $ne $nb -1 $ne $ne 1] {
                    if {$row != 0 && $col != 0} {
                        ::schem::la::spacc A [expr {$row-1}] [expr {$col-1}] [expr {$s*$gm}]
                    }
                }
                StampG A $nc $ne $gce
                set Iceq [expr {$Ic - $gm*$vbe0 - $gce*$vce0}]
                if {$nc != 0} { lset z [expr {$nc-1}] [expr {[lindex $z [expr {$nc-1}]] - $Iceq}] }
                if {$ne != 0} { lset z [expr {$ne-1}] [expr {[lindex $z [expr {$ne-1}]] + $Iceq}] }
            }
            set k 0
            foreach br $branches {
                lassign $br p q emf rs _
                set row [expr {$N + $k}]
                if {[dict exists $fbopen $k] || ([dict exists $b2buf $k] && ![dict exists $bufdrv $k])} {
                    # blown protective device, or a disabled (Hi-Z) tri-state
                    # buffer: force I_branch = 0 (open).
                    ::schem::la::spacc A $row $row 1.0
                    lset z $row 0.0
                } else {
                    if {[dict exists $b2buf $k]} {
                        # enabled buffer: drive its output through rout.
                        lassign [dict get $b2buf $k] _in _oe _vh ro
                        set emf [dict get $bufdrv $k] ; set rs $ro
                    }
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
            for {set mi 0} {$mi < [llength $mosfets]} {incr mi} {
                lassign [lindex $mosfets $mi] ng nd ns vto kp lambda pmos nm
                set vgs [expr {[Nv $x $ng] - [Nv $x $ns]}]
                set vds [expr {[Nv $x $nd] - [Nv $x $ns]}]
                set vgs0 [lindex $mosfetVgs $mi] ; set vds0 [lindex $mosfetVds $mi]
                if {$vgs - $vgs0 >  0.5} { set vgs [expr {$vgs0 + 0.5}] }
                if {$vgs0 - $vgs >  0.5} { set vgs [expr {$vgs0 - 0.5}] }
                if {$vds - $vds0 >  0.5} { set vds [expr {$vds0 + 0.5}] }
                if {$vds0 - $vds >  0.5} { set vds [expr {$vds0 - 0.5}] }
                set dv [expr {max(abs($vgs-$vgs0), abs($vds-$vds0))}]
                if {$dv > $maxd} { set maxd $dv }
                lset mosfetVgs $mi $vgs ; lset mosfetVds $mi $vds
            }
            for {set bi 0} {$bi < [llength $bjts]} {incr bi} {
                lassign [lindex $bjts $bi] nb nc ne is beta nf vaf pnp nm
                set vbe [expr {[Nv $x $nb] - [Nv $x $ne]}]
                set vce [expr {[Nv $x $nc] - [Nv $x $ne]}]
                set vbe0 [lindex $bjtVbe $bi] ; set vce0 [lindex $bjtVce $bi]
                if {$vbe - $vbe0 >  0.5} { set vbe [expr {$vbe0 + 0.5}] }
                if {$vbe0 - $vbe >  0.5} { set vbe [expr {$vbe0 - 0.5}] }
                if {$vce - $vce0 >  0.5} { set vce [expr {$vce0 + 0.5}] }
                if {$vce0 - $vce >  0.5} { set vce [expr {$vce0 - 0.5}] }
                set dv [expr {max(abs($vbe-$vbe0), abs($vce-$vce0))}]
                if {$dv > $maxd} { set maxd $dv }
                lset bjtVbe $bi $vbe ; lset bjtVce $bi $vce
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
        # Tri-state buffers: drive when output-enable is high, else release (Hi-Z).
        foreach buf $buffers {
            lassign $buf bi in oe vh ro nm
            set thr [expr {$vh/2.0}]
            if {[Nv $x $oe] > $thr} {
                set val [expr {[Nv $x $in] > $thr ? double($vh) : 0.0}]
                if {![dict exists $bufdrv $bi] || [dict get $bufdrv $bi] != $val} { dict set bufdrv $bi $val ; set changed 1 }
            } elseif {[dict exists $bufdrv $bi]} { dict unset bufdrv $bi ; set changed 1 }
        }
        if {!$changed} break
    }
    set v [dict create 0 0.0]
    for {set i 1} {$i <= $N} {incr i} { dict set v $i [lindex $x [expr {$i-1}]] }
    return $v
}

# my_stampG / nv -- helpers for the reference backend (node ids; 0 = ground).
