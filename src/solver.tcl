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
    namespace export solve matvec zeros
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
