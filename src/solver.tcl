# solver.tcl --
#
# Dense linear-system solver for Schem's circuit engine.
#
# The circuit engine reduces every schematic to a system of linear
# equations  A x = z  (Modified Nodal Analysis).  This file provides the
# numerical core: Gaussian elimination with partial pivoting.
#
# Matrices are represented as a Tcl list of rows; each row is a list of
# doubles.  Vectors are plain lists of doubles.  Everything is 0-indexed.
#
# This module knows nothing about electricity.  It is pure linear algebra
# so that it can be tested in isolation.

namespace eval ::schem::la {
    namespace export solve matvec zeros solve_sparse
}

# zeros -- allocate an n-vector (or n x m matrix) of 0.0
proc ::schem::la::zeros {n {m {}}} {
    if {$m eq {}} {
        return [lrepeat $n 0.0]
    }
    set row [lrepeat $m 0.0]
    return [lrepeat $n $row]
}

# matvec -- multiply matrix A (n x n, list of rows) by vector x.
proc ::schem::la::matvec {A x} {
    set out {}
    foreach row $A {
        set s 0.0
        foreach a $row xi $x { set s [expr {$s + $a * $xi}] }
        lappend out $s
    }
    return $out
}

# solve -- solve the dense linear system A x = b.
#
#   A   square matrix as a list of n rows, each a list of n doubles
#   b   right-hand-side vector of length n
#
# Returns the solution vector x.  Uses Gaussian elimination with partial
# pivoting.  Throws {SCHEM SINGULAR} if the matrix is numerically
# singular (a degenerate circuit -- e.g. an ideal short across a source,
# or a structurally indeterminate network).
proc ::schem::la::solve {A b} {
    set n [llength $b]
    if {$n == 0} { return {} }

    # Build an augmented working copy [A | b] so we never mutate the input.
    # Every entry is coerced to double so that integer literals in the
    # caller's matrix never trigger integer division during elimination.
    set M {}
    for {set i 0} {$i < $n} {incr i} {
        set row {}
        foreach v [lindex $A $i] { lappend row [expr {double($v)}] }
        lappend row [expr {double([lindex $b $i])}]
        lappend M $row
    }

    # Forward elimination with partial pivoting.
    for {set col 0} {$col < $n} {incr col} {
        # Find the pivot row: the largest magnitude entry in this column
        # at or below the diagonal.
        set pivot $col
        set best [expr {abs([lindex $M $col $col])}]
        for {set r [expr {$col + 1}]} {$r < $n} {incr r} {
            set v [expr {abs([lindex $M $r $col])}]
            if {$v > $best} { set best $v ; set pivot $r }
        }

        if {$best < 1e-14} {
            # Column has no usable pivot: the system is singular.
            return -code error -errorcode {SCHEM SINGULAR} \
                "singular system at column $col (degenerate circuit)"
        }

        # Swap the pivot row into place.
        if {$pivot != $col} {
            set tmp [lindex $M $col]
            lset M $col [lindex $M $pivot]
            lset M $pivot $tmp
        }

        # Eliminate this column from every row below the pivot.
        set prow [lindex $M $col]
        set pval [lindex $prow $col]
        for {set r [expr {$col + 1}]} {$r < $n} {incr r} {
            set rrow [lindex $M $r]
            set factor [expr {[lindex $rrow $col] / $pval}]
            if {$factor == 0.0} { continue }
            for {set c $col} {$c <= $n} {incr c} {
                lset rrow $c [expr {[lindex $rrow $c] - $factor * [lindex $prow $c]}]
            }
            lset M $r $rrow
        }
    }

    # Back substitution.
    set x [lrepeat $n 0.0]
    for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
        set row [lindex $M $i]
        set s [lindex $row $n]
        for {set c [expr {$i + 1}]} {$c < $n} {incr c} {
            set s [expr {$s - [lindex $row $c] * [lindex $x $c]}]
        }
        lset x $i [expr {$s / [lindex $row $i]}]
    }
    return $x
}

# solve_sparse -- solve A x = b where A is given *sparsely*.
#
#   Avar   name of an array in the caller, keyed "i,j" -> value (0-based);
#          absent keys are zero.  This is how a circuit matrix really looks:
#          almost every entry is zero, because each part touches a few nodes.
#   b      right-hand-side vector (a dense list of length n)
#   n      system size
#
# Same mathematics as `solve` (Gaussian elimination with partial pivoting)
# and the same {SCHEM SINGULAR} contract, but it only ever stores and works
# on the non-zero entries, so a large network costs far less than the dense
# O(n^3).  This is the engine's default path; `solve` stays for the
# isolated linear-algebra tests and tiny systems.
# spacc -- accumulate v into the sparse-matrix entry A(i,j) (array keyed
# "i,j" in the caller).  The workhorse of sparse stamping.
proc ::schem::la::spacc {Avar i j v} {
    if {$v == 0.0} return
    upvar 1 $Avar A
    set key $i,$j
    if {[info exists A($key)]} {
        set A($key) [expr {$A($key) + $v}]
    } else {
        set A($key) $v
    }
}

proc ::schem::la::solve_sparse {Avar b n} {
    upvar 1 $Avar A
    if {$n == 0} { return {} }

    # Build the matrix in its original indices first.
    set orow [dict create]
    for {set i 0} {$i < $n} {incr i} { dict set orow $i [dict create] }
    foreach key [array names A] {
        lassign [split $key ,] i j
        dict set orow $i $j [expr {double($A($key))}]
    }

    # Fill-reducing order: eliminate low-degree variables first, so the
    # high-degree power/ground rail nodes -- which would fill the matrix if
    # eliminated early -- go last.  A cheap static minimum-degree heuristic:
    # a variable's structural degree is its row's non-zero count.  Partial
    # pivoting below still guarantees numerical stability on top of it.
    set order {}
    for {set i 0} {$i < $n} {incr i} { lappend order [list [dict size [dict get $orow $i]] $i] }
    set perm {}
    foreach pair [lsort -integer -index 0 $order] { lappend perm [lindex $pair 1] }
    set pos [dict create]
    for {set k 0} {$k < $n} {incr k} { dict set pos [lindex $perm $k] $k }

    # Re-express the matrix and RHS in elimination order.  Two cross-linked
    # views: row k -> (col -> value); col j -> (row -> 1).  The column view
    # lets each step touch only the rows that couple to the pivot.
    set row [dict create] ; set col [dict create] ; set b2 [lrepeat $n 0.0]
    for {set k 0} {$k < $n} {incr k} { dict set row $k [dict create] }
    for {set k 0} {$k < $n} {incr k} {
        set oi [lindex $perm $k]
        lset b2 $k [expr {double([lindex $b $oi])}]
        dict for {oj v} [dict get $orow $oi] {
            set pj [dict get $pos $oj]
            dict set row $k $pj $v
            dict set col $pj $k 1
        }
    }
    set b $b2

    # Forward elimination with partial pivoting.
    for {set k 0} {$k < $n} {incr k} {
        # Pivot: largest-magnitude entry in column k at or below the diagonal.
        set pivot -1 ; set best 0.0
        if {[dict exists $col $k]} {
            dict for {i _} [dict get $col $k] {
                if {$i < $k} continue
                set v [expr {abs([dict get $row $i $k])}]
                if {$v > $best} { set best $v ; set pivot $i }
            }
        }
        if {$best < 1e-14} {
            return -code error -errorcode {SCHEM SINGULAR} \
                "singular system at column $k (degenerate circuit)"
        }
        # Swap the pivot row into position k (updating the column view and b).
        if {$pivot != $k} {
            foreach j [dict keys [dict get $row $k]]     { dict unset col $j $k }
            foreach j [dict keys [dict get $row $pivot]] { dict unset col $j $pivot }
            set tmp [dict get $row $k]
            dict set row $k [dict get $row $pivot]
            dict set row $pivot $tmp
            foreach j [dict keys [dict get $row $k]]     { dict set col $j $k 1 }
            foreach j [dict keys [dict get $row $pivot]] { dict set col $j $pivot 1 }
            set t [lindex $b $k] ; lset b $k [lindex $b $pivot] ; lset b $pivot $t
        }
        set prow [dict get $row $k]
        set pval [dict get $prow $k]
        set bk [lindex $b $k]
        # Eliminate column k from exactly the rows below that touch it.
        set targets {}
        dict for {i _} [dict get $col $k] { if {$i > $k} { lappend targets $i } }
        foreach i $targets {
            set irow [dict get $row $i]
            set factor [expr {[dict get $irow $k] / $pval}]
            dict for {c v} $prow {
                if {$c == $k} continue
                if {[dict exists $irow $c]} {
                    dict set irow $c [expr {[dict get $irow $c] - $factor*$v}]
                } else {
                    dict set irow $c [expr {-$factor*$v}]   ;# fill-in
                    dict set col $c $i 1
                }
            }
            dict unset irow $k
            dict unset col $k $i
            dict set row $i $irow
            lset b $i [expr {[lindex $b $i] - $factor*$bk}]
        }
    }

    # Back substitution (in elimination order).
    set xp [lrepeat $n 0.0]
    for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
        set irow [dict get $row $i]
        set s [lindex $b $i]
        dict for {c v} $irow {
            if {$c > $i} { set s [expr {$s - $v * [lindex $xp $c]}] }
        }
        lset xp $i [expr {$s / [dict get $irow $i]}]
    }
    # Un-permute: variable perm[k] was eliminated at position k.
    set x [lrepeat $n 0.0]
    for {set k 0} {$k < $n} {incr k} { lset x [lindex $perm $k] [lindex $xp $k] }
    return $x
}
