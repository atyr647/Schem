#!/usr/bin/env tclsh
# run.tcl -- test runner for the FPGA side project (separate from core Schem).
#
# Runs every fpga/tests/test_*.tcl under tclsh, prints one line per suite and a
# summary, and exits nonzero on any failure.  All suites are headless (no Tk).
# The compiled-backend suites self-skip without a Zig compiler; set SCHEM_ZIG
# (or put `zig` on PATH) to exercise them.
#
#   tclsh fpga/tests/run.tcl            # all suites
#   tclsh fpga/tests/run.tcl fpga zig   # only matching suites
#   SCHEM_ZIG=/path/to/zig tclsh fpga/tests/run.tcl

set here [file dirname [file normalize [info script]]]
set want [lrange $argv 0 end]

set suites [lsort [glob -nocomplain -directory $here test_*.tcl]]
set passed 0 ; set failed 0 ; set failset {}

foreach s $suites {
    set name [file tail $s]
    if {[llength $want]} {
        set match 0
        foreach w $want { if {[string match *$w* $name]} { set match 1 ; break } }
        if {!$match} continue
    }
    if {[catch {exec [info nameofexecutable] $s} out]} {
        # nonzero exit -> at least one case failed (or the suite errored).
        set ok 0
    } else {
        set ok 1
    }
    # the last "N passed, M failed" line is authoritative when present.
    set summary ""
    foreach line [split $out \n] {
        if {[regexp {([0-9]+) passed, ([0-9]+) failed} $line -> p f]} { set summary "$p passed, $f failed" }
    }
    if {$ok && $summary ne "" && ![string match {*, 0 failed} $summary]} { set ok 0 }
    if {$ok} {
        incr passed ; puts [format "  %-22s ok   (%s)" $name $summary]
    } else {
        incr failed ; lappend failset $name
        puts [format "  %-22s FAIL (%s)" $name $summary]
        puts $out
    }
}

puts ""
puts "suites: $passed ok, $failed failed"
if {$failed} { puts "failing: [join $failset {, }]" ; exit 1 }
exit 0
