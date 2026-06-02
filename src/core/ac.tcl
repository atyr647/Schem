# ac.tcl -- Small-signal AC (frequency-domain) analysis.
#
# Adds `acsweep` to ::schem::Schematic.  At each frequency the schematic is
# linearised at the DC operating point (nonlinear devices contribute their
# small-signal conductances) and the complex MNA system is solved.
#
# The complex n×n system  A·x = z  is converted to an equivalent 2n×2n real
# system by replacing every complex entry a+jb with the 2×2 block
#   [[a, -b],
#    [b,  a]]
# This lets the existing Gaussian-elimination logic solve complex problems with
# no new numerical code.
#
# Returned dict:  freq(Hz) -> node-id -> {re im}
# Helper methods `acmag` and `acphase` convert to dB / degrees.

namespace eval ::schem::ac {}

# ============================================================
#  Dense complex MNA solver (via 2n×2n real expansion)
# ============================================================

# AcSolve -- solve a complex linear system A·x = z.
# A is a flat list of n*n {re im} pairs (row-major).
# z is a list of n {re im} pairs.
# Returns a list of n {re im} pairs.
proc ::schem::ac::AcSolve {A z n} {
    set n2 [expr {$n * 2}]
    # expand to a (2n)×(2n) real matrix
    set R [lrepeat [expr {$n2 * $n2}] 0.0]
    set rz [lrepeat $n2 0.0]
    for {set r 0} {$r < $n} {incr r} {
        for {set c 0} {$c < $n} {incr c} {
            set e [lindex $A [expr {$r*$n+$c}]]
            set er [lindex $e 0] ; set ei [lindex $e 1]
            # [[er, -ei],[ei, er]] at real block (r,c)
            lset R [expr {$r     * $n2 + $c    }] $er
            lset R [expr {$r     * $n2 + $c+$n }] [expr {-$ei}]
            lset R [expr {($r+$n)* $n2 + $c    }] $ei
            lset R [expr {($r+$n)* $n2 + $c+$n }] $er
        }
        set zv [lindex $z $r]
        lset rz $r       [lindex $zv 0]
        lset rz [expr {$r+$n}] [lindex $zv 1]
    }
    # Gaussian elimination with partial pivoting
    for {set k 0} {$k < $n2} {incr k} {
        # find pivot row
        set piv $k ; set best [expr {abs([lindex $R [expr {$k*$n2+$k}]])}]
        for {set i [expr {$k+1}]} {$i < $n2} {incr i} {
            set v [expr {abs([lindex $R [expr {$i*$n2+$k}]])}]
            if {$v > $best} { set best $v ; set piv $i }
        }
        if {$piv != $k} {
            for {set c 0} {$c < $n2} {incr c} {
                set t [lindex $R [expr {$k*$n2+$c}]]
                lset R [expr {$k*$n2+$c}]   [lindex $R [expr {$piv*$n2+$c}]]
                lset R [expr {$piv*$n2+$c}] $t
            }
            set t [lindex $rz $k] ; lset rz $k [lindex $rz $piv] ; lset rz $piv $t
        }
        set pv [lindex $R [expr {$k*$n2+$k}]]
        if {$pv == 0.0} continue
        for {set i [expr {$k+1}]} {$i < $n2} {incr i} {
            set f [expr {[lindex $R [expr {$i*$n2+$k}]] / $pv}]
            if {$f == 0.0} continue
            for {set c $k} {$c < $n2} {incr c} {
                lset R [expr {$i*$n2+$c}] \
                    [expr {[lindex $R [expr {$i*$n2+$c}]] - $f * [lindex $R [expr {$k*$n2+$c}]]}]
            }
            lset rz $i [expr {[lindex $rz $i] - $f * [lindex $rz $k]}]
        }
    }
    # back substitution
    for {set ii [expr {$n2-1}]} {$ii >= 0} {incr ii -1} {
        set s [lindex $rz $ii]
        for {set c [expr {$ii+1}]} {$c < $n2} {incr c} {
            set s [expr {$s - [lindex $R [expr {$ii*$n2+$c}]] * [lindex $rz $c]}]
        }
        lset rz $ii [expr {$s / [lindex $R [expr {$ii*$n2+$ii}]]}]
    }
    # reassemble complex result
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        lappend out [list [lindex $rz $i] [lindex $rz [expr {$i+$n}]]]
    }
    return $out
}

# Nac -- helper: pick node voltage (complex) from result vector.
proc ::schem::ac::Nac {x nid} {
    return [expr {$nid == 0 ? [list 0.0 0.0] : [lindex $x [expr {$nid-1}]]}]
}

# ============================================================
#  acsweep method
# ============================================================

oo::define ::schem::Schematic {

    # acsweep -- AC frequency sweep.
    #
    # acsweep FREQS ?-source NAME? ?-amp A? ?-phase P?
    #
    # FREQS   list of frequencies in Hz.
    # -source the battery whose EMF is the AC stimulus (default: first battery).
    #         All other DC sources are shorted for AC (ideal 0 V branches).
    # -amp    AC source amplitude (V, default 1.0).
    # -phase  AC source phase (degrees, default 0.0).
    #
    # Returns a dict  freq -> {node-id -> {re im}}, node 0 = ground = {0 0}.
    # Use `acmag` and `acphase` to convert to dB / degrees.
    method acsweep {freqs args} {
        # parse options
        set acSrc "" ; set acAmp 1.0 ; set acPhaseDeg 0.0
        foreach {k v} $args {
            switch -- $k {
                -source { set acSrc $v }
                -amp    { set acAmp $v }
                -phase  { set acPhaseDeg $v }
                default { return -code error "acsweep: unknown option $k" }
            }
        }
        # resolve DC operating point (linearises nonlinear devices)
        my solve
        my BuildNodes

        # pick default AC source (first battery)
        if {$acSrc eq ""} {
            dict for {nm c} $Comp {
                if {[dict get $c type] eq "battery"} { set acSrc $nm ; break }
            }
        }
        if {$acSrc eq "" || ![dict exists $Comp $acSrc]} {
            return -code error "acsweep: no AC source found (use -source NAME)"
        }
        if {[dict get $Comp $acSrc type] ne "battery"} {
            return -code error "acsweep: source \"$acSrc\" is not a battery"
        }

        # AC phasor of the source (complex)
        set phRad [expr {$acPhaseDeg * 3.14159265358979323846 / 180.0}]
        set acEmfRe [expr {$acAmp * cos($phRad)}]
        set acEmfIm [expr {$acAmp * sin($phRad)}]

        # ---- count branches (voltage sources + inductors) ----
        set branches {}   ;# {p q emfRe emfIm zRe zIm name}  (complex branch)
        set conds    {}   ;# {na nb gRe gIm name}
        set caps     {}   ;# {na nb C}
        set inds     {}   ;# {na nb L r}

        dict for {name comp} $Comp {
            set t [dict get $comp type]
            set nd {}
            foreach pin [my terminals $name] { dict set nd $pin [my NodeOf $name.$pin] }
            switch $t {
                battery {
                    set emfRe 0.0 ; set emfIm 0.0
                    if {$name eq $acSrc} { set emfRe $acEmfRe ; set emfIm $acEmfIm }
                    set rs [dict get $comp params esr]
                    lappend branches [list [dict get $nd pos] [dict get $nd neg] \
                        $emfRe $emfIm $rs 0.0 $name]
                }
                ground {}
                resistor {
                    set r [dict get $comp params r]
                    lappend conds [list [dict get $nd a] [dict get $nd b] \
                        [expr {1.0/$r}] 0.0 $name]
                }
                capacitor {
                    lappend caps [list [dict get $nd a] [dict get $nd b] \
                        [dict get $comp params c]]
                }
                inductor {
                    lappend inds [list [dict get $nd a] [dict get $nd b] \
                        [dict get $comp params l] [dict get $comp params r]]
                }
                switch - button {
                    set st [dict get $comp params state]
                    if {$st in {closed pressed}} {
                        variable ::schem::RSMALL
                        lappend conds [list [dict get $nd a] [dict get $nd b] \
                            [expr {1.0/$RSMALL}] 0.0 $name]
                    }
                }
                relay {
                    set pr [dict get $comp params]
                    set rcoil [dict get $pr coil]
                    set lcoil [dict get $pr coilL]
                    # coil conductance (purely real at DC, but frequency-dependent with L)
                    lappend inds [list [my NodeOf $name.c1] [my NodeOf $name.c2] $lcoil $rcoil]
                    # contact
                    variable ::schem::RSMALL
                    set en [expr {[dict exists $Energized $name] && [dict get $Energized $name]}]
                    if {$en} {
                        lappend conds [list [my NodeOf $name.com] [my NodeOf $name.no] \
                            [expr {1.0/$RSMALL}] 0.0 $name.contact]
                    } else {
                        lappend conds [list [my NodeOf $name.com] [my NodeOf $name.nc] \
                            [expr {1.0/$RSMALL}] 0.0 $name.contact]
                    }
                }
                fuse - breaker {
                    set pr [dict get $comp params]
                    set okst [expr {$t eq "fuse" ? "intact" : "closed"}]
                    if {[dict get $pr state] eq $okst} {
                        lappend branches [list [dict get $nd a] [dict get $nd b] \
                            0.0 0.0 0.0 0.0 $name]
                    }
                }
                ammeter {
                    lappend branches [list [dict get $nd a] [dict get $nd b] \
                        0.0 0.0 0.0 0.0 $name]
                }
                diode {
                    # small-signal conductance at DC operating point
                    set vj [expr {[my probe $name.a] - [my probe $name.k]}]
                    set pr [dict get $comp params]
                    set Vt [expr {0.025852 * [dict get $pr n]}]
                    set ef [expr {exp(min($vj/$Vt, 80.0))}]
                    set gj [expr {max([dict get $pr is]*$ef/$Vt, 1e-12)}]
                    lappend conds [list [dict get $nd a] [dict get $nd k] $gj 0.0 $name]
                }
                mosfet {
                    # small-signal gm (VCCS) + gds at DC operating point
                    set vgs [expr {[my probe $name.g] - [my probe $name.s]}]
                    set vds [expr {[my probe $name.d] - [my probe $name.s]}]
                    lassign [my MosfetGI $name $vgs $vds] _Id gm gds
                    lappend conds [list [dict get $nd d] [dict get $nd s] $gds 0.0 $name.gds]
                    # VCCS gm*(Vg-Vs): stored separately, handled in stamp
                    lappend conds [list -1 -1 $gm 0.0 "$name.vccs [dict get $nd d] [dict get $nd s] [dict get $nd g] [dict get $nd s]"]
                }
                bjt {
                    set vbe [expr {[my probe $name.b] - [my probe $name.e]}]
                    set vce [expr {[my probe $name.c] - [my probe $name.e]}]
                    lassign [my BjtGI $name $vbe $vce] _Ic _Ib gm gbe gce
                    lappend conds [list [dict get $nd b] [dict get $nd e] $gbe 0.0 $name.gbe]
                    lappend conds [list [dict get $nd c] [dict get $nd e] $gce 0.0 $name.gce]
                    lappend conds [list -1 -1 $gm 0.0 "$name.vccs [dict get $nd c] [dict get $nd e] [dict get $nd b] [dict get $nd e]"]
                }
                transformer {
                    # ideal coupled inductors -- add two inductive branches
                    set pr [dict get $comp params]
                    lappend inds [list [dict get $nd p1] [dict get $nd n1] [dict get $pr l1] 0.0]
                    lappend inds [list [dict get $nd p2] [dict get $nd n2] [dict get $pr l2] 0.0]
                }
                bus - junction {}
                memory - buffer {}
            }
        }

        # build gauged wire conductances
        foreach c $Conns {
            lassign $c ta tb awg hn len
            if {$awg eq ""} continue
            variable ::schem::RESPERM
            if {![info exists RESPERM($awg)] || $len eq ""} continue
            set r [expr {$RESPERM($awg) * double($len)}]
            if {$r > 0} {
                lappend conds [list [my NodeOf $ta] [my NodeOf $tb] [expr {1.0/$r}] 0.0 "wire"]
            }
        }

        # ---- per-frequency solve ----
        set N $NNodes
        set SZ [expr {$N + [llength $branches] + [llength $inds]}]

        set results [dict create]

        foreach freq $freqs {
            set om [expr {2.0 * 3.14159265358979323846 * $freq}]

            # initialise complex matrix A (SZ×SZ) and RHS z (SZ), both {re im}
            set A [lrepeat [expr {$SZ * $SZ}] {0.0 0.0}]
            set z [lrepeat $SZ {0.0 0.0}]
            # regulariser
            for {set i 0} {$i < $N} {incr i} {
                lset A [expr {$i*$SZ+$i}] {1e-12 0.0}
            }

            # stamp conductances (real or complex; VCCS entries have llength(nm)>1)
            foreach c $conds {
                lassign $c na nb gre gim nm
                if {[llength $nm] > 1} {
                    # VCCS: "compname nP nN nC nD" — voltage-controlled current source
                    lassign $nm _name nP nN nC nD
                    set g $gre
                    foreach {r c s} [list $nP $nC 1  $nP $nD -1  $nN $nC -1  $nN $nD 1] {
                        if {$r <= 0 || $c <= 0} continue
                        set ri [expr {$r-1}] ; set ci [expr {$c-1}]
                        set idx [expr {$ri*$SZ+$ci}]
                        set cur [lindex $A $idx]
                        lset A $idx [list [expr {[lindex $cur 0]+$s*$g}] [lindex $cur 1]]
                    }
                    continue
                }
                # regular two-terminal conductance; ground (node 0) handled by the
                # row<0/col<0 guard inside the loop — do NOT skip here.
                set r [expr {$na-1}] ; set c [expr {$nb-1}]
                foreach {row col s} [list $r $r 1  $c $c 1  $r $c -1  $c $r -1] {
                    if {$row < 0 || $col < 0} continue
                    set idx [expr {$row*$SZ+$col}]
                    set cur [lindex $A $idx]
                    lset A $idx [list \
                        [expr {[lindex $cur 0] + $s*$gre}] \
                        [expr {[lindex $cur 1] + $s*$gim}]]
                }
            }

            # stamp capacitors: Y = j*om*C (purely imaginary conductance)
            foreach cp $caps {
                lassign $cp na nb C
                if {$na <= 0 && $nb <= 0} continue
                set gim [expr {$om * $C}]
                foreach {row col s} \
                    [list [expr {$na-1}] [expr {$na-1}] 1 \
                          [expr {$nb-1}] [expr {$nb-1}] 1 \
                          [expr {$na-1}] [expr {$nb-1}] -1 \
                          [expr {$nb-1}] [expr {$na-1}] -1] {
                    if {$row < 0 || $col < 0} continue
                    set idx [expr {$row*$SZ+$col}]
                    set cur [lindex $A $idx]
                    lset A $idx [list [lindex $cur 0] [expr {[lindex $cur 1] + $s*$gim}]]
                }
            }

            # stamp inductors as branches: impedance Z = r + j*om*L
            set row $N
            foreach ind $inds {
                lassign $ind na nb L r
                set na [expr {$na-1}] ; set nb [expr {$nb-1}]
                # branch row: stamp ±1 in node rows, -Z in branch diagonal
                if {$na >= 0} {
                    set idx [expr {$na*$SZ+$row}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]+1.0}] [lindex $cur 1]]
                    set idx [expr {$row*$SZ+$na}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]+1.0}] [lindex $cur 1]]
                }
                if {$nb >= 0} {
                    set idx [expr {$nb*$SZ+$row}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]-1.0}] [lindex $cur 1]]
                    set idx [expr {$row*$SZ+$nb}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]-1.0}] [lindex $cur 1]]
                }
                # diagonal: -Z = -(r + j*om*L)
                set zRe [expr {-$r}] ; set zIm [expr {-$om * $L}]
                # avoid singular if L=0 and r=0: small regulariser
                if {$L == 0.0 && $r == 0.0} { set zRe -1e-9 }
                set idx [expr {$row*$SZ+$row}]
                set cur [lindex $A $idx]
                lset A $idx [list [expr {[lindex $cur 0]+$zRe}] [expr {[lindex $cur 1]+$zIm}]]
                incr row
            }

            # stamp voltage-source branches
            foreach br $branches {
                lassign $br p q emfRe emfIm zRe zIm nm
                set p [expr {$p-1}] ; set q [expr {$q-1}]
                if {$p >= 0} {
                    set idx [expr {$p*$SZ+$row}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]+1.0}] [lindex $cur 1]]
                    set idx [expr {$row*$SZ+$p}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]+1.0}] [lindex $cur 1]]
                }
                if {$q >= 0} {
                    set idx [expr {$q*$SZ+$row}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]-1.0}] [lindex $cur 1]]
                    set idx [expr {$row*$SZ+$q}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]-1.0}] [lindex $cur 1]]
                }
                if {$zRe != 0.0} {
                    set idx [expr {$row*$SZ+$row}] ; set cur [lindex $A $idx]
                    lset A $idx [list [expr {[lindex $cur 0]-$zRe}] [lindex $cur 1]]
                }
                lset z $row [list $emfRe $emfIm]
                incr row
            }

            # solve
            set x [::schem::ac::AcSolve $A $z $SZ]

            # extract node voltages (0-indexed result -> 1-indexed node)
            set nv [dict create 0 {0.0 0.0}]
            for {set i 1} {$i <= $N} {incr i} {
                dict set nv $i [lindex $x [expr {$i-1}]]
            }
            dict set results $freq $nv
        }
        return $results
    }

    # acmag -- magnitude in dB from an acsweep result phasor.
    method acmag {phasor} {
        set re [lindex $phasor 0] ; set im [lindex $phasor 1]
        set mag [expr {sqrt($re*$re + $im*$im)}]
        if {$mag <= 0} { return -999.0 }
        return [expr {20.0 * log10($mag)}]
    }

    # acphase -- phase in degrees from an acsweep result phasor.
    method acphase {phasor} {
        return [expr {atan2([lindex $phasor 1], [lindex $phasor 0]) * (180.0 / 3.14159265358979323846)}]
    }

    # acnode -- look up a terminal's node phasor from an acsweep result dict.
    method acnode {sweep_result freq term} {
        set nid [my NodeOf $term]
        return [dict get $sweep_result $freq $nid]
    }
}
