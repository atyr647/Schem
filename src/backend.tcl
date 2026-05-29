# backend.tcl --
#
# Backends consume the Circuit IR (src/compile.tcl) and emit a target.  They
# are interchangeable: each is a proc ::schem::backend::<name> {cir} returning
# the emitted text, registered just by existing.  The IR is the contract, so
# adding C / WASM / HDL later means adding a sibling proc -- no engine change.
#
#     schematic -> Circuit IR ->  [ zig | c | wasm | hdl | ... ]
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
    foreach c [info commands ::schem::backend::*] { lappend out [namespace tail $c] }
    return [lsort $out]
}

# ====================================================================
#  Zig backend -- emit a self-contained Zig program that solves the DC
#  operating point of the circuit by Modified Nodal Analysis.
# ====================================================================
#
# Scope (v1): the *linear* DC elements at their stated device state --
# resistors, batteries (with internal resistance), closed switches/buttons,
# ammeters, gauged wires, intact fuses, closed breakers, and inductors
# (a short at DC); capacitors are open at DC and drop out.  Elements whose
# behaviour is nonlinear (diodes) or whose contacts are decided by the
# solver's own state loop (relays) or that are magnetically coupled
# (transformers) need the Newton / fixed-point / transient code-gen layer and
# are reported as unsupported -- the IR already carries everything that layer
# will need (pick-up/drop-out/delay, Shockley is/n/rs/bv, companion values).
# LowerDC -- shared lowering used by every DC backend.  Classifies the IR's
# elements into conductances and voltage-source branches exactly as the MNA
# engine does, refusing the classes that need the nonlinear/stateful/transient
# code-gen layer (diodes, relays, transformers).  Returns {conds branches}:
#   conds    list of {na nb g label}
#   branches list of {p q emf rs owner}
proc ::schem::backend::LowerDC {cir} {
    set conds {} ; set branches {} ; set unsupported {}
    foreach e [dict get $cir elements] {
        set nm [dict get $e name]
        switch [dict get $e class] {
            conductance {
                set nd [dict get $e nodes]
                lappend conds [list [dict get $nd a] [dict get $nd b] [dict get $e g] "$nm ([dict get $e type])"]
            }
            source {
                set nd [dict get $e nodes]
                lappend branches [list [dict get $nd pos] [dict get $nd neg] [dict get $e emf] [dict get $e rs] $nm]
            }
            switch {
                if {[dict get $e state] in {closed pressed}} {
                    set nd [dict get $e nodes]
                    lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/[dict get $e r_closed]}] "$nm (closed [dict get $e type])"]
                }
            }
            meter {
                set nd [dict get $e nodes]
                lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm]
            }
            protective {
                if {[dict get $e state] in {intact closed}} {
                    set nd [dict get $e nodes]
                    lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm]
                }
            }
            conductor {
                set nd [dict get $e nodes] ; set r [dict get $e r]
                if {$r > 0} {
                    lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/$r}] "$nm (wire [dict get $e awg]AWG)"]
                } else {
                    lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm]
                }
            }
            reactive {
                if {[dict get $e type] eq "inductor"} {
                    set nd [dict get $e nodes] ; set r [dict get $e r]
                    if {$r > 0} {
                        lappend conds [list [dict get $nd a] [dict get $nd b] [expr {1.0/$r}] "$nm (inductor DC, winding R)"]
                    } else {
                        lappend branches [list [dict get $nd a] [dict get $nd b] 0.0 0.0 $nm]
                    }
                }
                # capacitor: open at DC -> no stamp
            }
            default { lappend unsupported "$nm ([dict get $e type])" }
        }
    }
    if {[llength $unsupported]} {
        return -code error "DC backend does not yet support: [join $unsupported {, }].\
 These need the nonlinear/stateful/transient code-gen layer; the IR already carries their parameters."
    }
    return [list $conds $branches]
}

# dcref -- a reference backend, in Tcl, that solves the DC operating point
# straight from the Circuit IR (the same lowering the emitters use).  Returns
# a dict node-id -> voltage.  It proves the IR carries enough to reproduce the
# solve, and serves as the oracle the code-emitting backends are checked against.
proc ::schem::backend::dcref {cir} {
    set N [dict get $cir nodes count]
    lassign [::schem::backend::LowerDC $cir] conds branches
    set B [llength $branches]
    set SZ [expr {$N + $B}]
    if {$SZ == 0} { return [dict create] }
    unset -nocomplain A ; array set A {}
    set z [lrepeat $SZ 0.0]
    for {set i 0} {$i < $N} {incr i} { ::schem::la::spacc A $i $i 1e-12 }
    foreach c $conds {
        lassign $c na nb g _
        if {$na != 0} { ::schem::la::spacc A [expr {$na-1}] [expr {$na-1}] $g }
        if {$nb != 0} { ::schem::la::spacc A [expr {$nb-1}] [expr {$nb-1}] $g }
        if {$na != 0 && $nb != 0} {
            ::schem::la::spacc A [expr {$na-1}] [expr {$nb-1}] [expr {-$g}]
            ::schem::la::spacc A [expr {$nb-1}] [expr {$na-1}] [expr {-$g}]
        }
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
    set v [dict create 0 0.0]
    for {set i 1} {$i <= $N} {incr i} { dict set v $i [lindex $x [expr {$i-1}]] }
    return $v
}

proc ::schem::backend::zig {cir} {
    set N [dict get $cir nodes count]
    set nmap [dict get $cir nodes map]
    lassign [::schem::backend::LowerDC $cir] conds branches
    set B [llength $branches]
    set SZ [expr {$N + $B}]

    # node-index helper: node id k (1..N) -> matrix index k-1; ground (0) skipped.
    set idx {nid {expr {$nid - 1}}}

    # --- emit straight-line stamps (indices are known at compile time) ---
    set stamps {}
    lappend stamps "    // conductances (Ohm's law)"
    foreach c $conds {
        lassign $c na nb g cm
        lappend stamps "    // $cm"
        if {$na != 0} { lappend stamps "    a\[[expr {($na-1)}] * SZ + [expr {($na-1)}]\] += $g;" }
        if {$nb != 0} { lappend stamps "    a\[[expr {($nb-1)}] * SZ + [expr {($nb-1)}]\] += $g;" }
        if {$na != 0 && $nb != 0} {
            lappend stamps "    a\[[expr {($na-1)}] * SZ + [expr {($nb-1)}]\] -= $g;"
            lappend stamps "    a\[[expr {($nb-1)}] * SZ + [expr {($na-1)}]\] -= $g;"
        }
    }
    lappend stamps "    // voltage-source / ideal-conductor branches"
    set k 0
    foreach br $branches {
        lassign $br p q emf rs owner
        set row [expr {$N + $k}]
        lappend stamps "    // branch $owner  (row $row)"
        if {$p != 0} {
            lappend stamps "    a\[[expr {($p-1)}] * SZ + $row\] += 1.0;"
            lappend stamps "    a\[$row * SZ + [expr {($p-1)}]\] += 1.0;"
        }
        if {$q != 0} {
            lappend stamps "    a\[[expr {($q-1)}] * SZ + $row\] -= 1.0;"
            lappend stamps "    a\[$row * SZ + [expr {($q-1)}]\] -= 1.0;"
        }
        if {$rs != 0} { lappend stamps "    a\[$row * SZ + $row\] -= $rs;" }
        lappend stamps "    z\[$row\] = $emf;"
        incr k
    }

    # --- emit per-node print lines ---
    set prints {}
    dict for {nid terms} $nmap {
        if {$nid == 0} continue
        set ix [expr {$nid - 1}]
        lappend prints "    // N$nid : [join $terms { }]"
        lappend prints "    try stdout.print(\"  N{d} = {d:.4} V\\n\", .{ $nid, z\[$ix\] });"
    }

    # --- assemble the program ---
    set name [dict get $cir name]
    set src {}
    lappend src "// Generated by Schem -- DC operating point of \"$name\""
    lappend src "// Derived from the Circuit IR; the .schem schematic is the source."
    lappend src "// $N node(s) + $B branch(es) = $SZ unknown(s).  Build: zig run this.zig"
    lappend src "const std = @import(\"std\");"
    lappend src ""
    lappend src "const N: usize = $N;        // non-ground nodes"
    lappend src "const SZ: usize = $SZ;       // + source/conductor branches"
    lappend src ""
    lappend src "// Gaussian elimination with partial pivoting (A x = z; result in z)."
    lappend src "fn solve(a: \[\]f64, z: \[\]f64, n: usize) void {"
    lappend src "    var k: usize = 0;"
    lappend src "    while (k < n) : (k += 1) {"
    lappend src "        var piv = k;"
    lappend src "        var best = @abs(a\[k * n + k\]);"
    lappend src "        var i = k + 1;"
    lappend src "        while (i < n) : (i += 1) {"
    lappend src "            const v = @abs(a\[i * n + k\]);"
    lappend src "            if (v > best) { best = v; piv = i; }"
    lappend src "        }"
    lappend src "        if (piv != k) {"
    lappend src "            var c: usize = 0;"
    lappend src "            while (c < n) : (c += 1) {"
    lappend src "                const t = a\[k * n + c\]; a\[k * n + c\] = a\[piv * n + c\]; a\[piv * n + c\] = t;"
    lappend src "            }"
    lappend src "            const tz = z\[k\]; z\[k\] = z\[piv\]; z\[piv\] = tz;"
    lappend src "        }"
    lappend src "        const pv = a\[k * n + k\];"
    lappend src "        i = k + 1;"
    lappend src "        while (i < n) : (i += 1) {"
    lappend src "            const f = a\[i * n + k\] / pv;"
    lappend src "            if (f == 0) continue;"
    lappend src "            var c: usize = k;"
    lappend src "            while (c < n) : (c += 1) { a\[i * n + c\] -= f * a\[k * n + c\]; }"
    lappend src "            z\[i\] -= f * z\[k\];"
    lappend src "        }"
    lappend src "    }"
    lappend src "    var ii: usize = n;"
    lappend src "    while (ii > 0) {"
    lappend src "        ii -= 1;"
    lappend src "        var s = z\[ii\];"
    lappend src "        var c: usize = ii + 1;"
    lappend src "        while (c < n) : (c += 1) { s -= a\[ii * n + c\] * z\[c\]; }"
    lappend src "        z\[ii\] = s / a\[ii * n + ii\];"
    lappend src "    }"
    lappend src "}"
    lappend src ""
    lappend src "pub fn main() !void {"
    lappend src "    const stdout = std.io.getStdOut().writer();"
    lappend src "    var a = \[_\]f64{0} ** (SZ * SZ);"
    lappend src "    var z = \[_\]f64{0} ** SZ;"
    lappend src ""
    lappend src "    // gmin: a tiny conductance to ground keeps the system non-singular."
    lappend src "    { var i: usize = 0; while (i < N) : (i += 1) { a\[i * SZ + i\] += 1e-12; } }"
    lappend src ""
    foreach line $stamps { lappend src $line }
    lappend src ""
    lappend src "    solve(a\[0..\], z\[0..\], SZ);"
    lappend src ""
    lappend src "    try stdout.print(\"DC operating point of \\\"$name\\\" (ground = 0 V)\\n\", .{});"
    foreach line $prints { lappend src $line }
    lappend src "}"
    return [join $src \n]
}
