#!/usr/bin/env tclsh
# run.tcl -- the unified test runner.
#
# Runs every tests/test_*.tcl, choosing the right interpreter (GUI/symbol
# suites need wish + a display; the rest use tclsh), and prints a single
# pass/fail summary.  Exit status is nonzero if any suite failed.
#
#   tclsh tests/run.tcl            # run all
#   tclsh tests/run.tcl parts pcb  # run only matching suites
#
# Honours SCHEM_ZIG (or a `zig` on PATH) for the compiled-backend cross-checks;
# GUI/symbol suites self-skip when Tk or a display is unavailable.

set here [file dirname [file normalize [info script]]]
set filter [lrange $argv 0 end]

# which suites need wish (Tk)?
set needTk {test_gui.tcl test_ksym.tcl}

# locate wish (for the Tk suites)
proc findWish {} {
    foreach c {wish wish8.6} { if {[set p [auto_execok $c]] ne ""} { return $p } }
    return ""
}
set wish [findWish]

set suites [lsort [glob -nocomplain -directory $here test_*.tcl]]
set total 0 ; set passed 0 ; set failed 0 ; set skipped 0
set failedNames {}

foreach s $suites {
    set name [file tail $s]
    if {[llength $filter]} {
        set match 0
        foreach f $filter { if {[string match *$f* $name]} { set match 1 } }
        if {!$match} continue
    }
    set tk [expr {$name in $needTk}]
    if {$tk && $wish eq ""} {
        puts [format "  %-20s SKIP (no wish/Tk)" $name] ; incr skipped ; continue
    }
    set exe [expr {$tk ? $wish : [info nameofexecutable]}]
    incr total
    if {[catch {exec {*}$exe $s} out options]} {
        # nonzero exit -> failed (unless it self-reported a skip)
        set code [dict get $options -errorcode]
    }
    # parse the trailing "N passed, M failed" or tcltest "Failed N"
    set p "?" ; set f "?"
    if {[regexp {([0-9]+) passed, ([0-9]+) failed} $out -> p f]} {
    } elseif {[regexp {Total\s+(\d+).*Passed\s+(\d+).*Failed\s+(\d+)} $out -> tt pp f]} {
        set p $pp
    }
    if {[string is integer -strict $f] && $f == 0} {
        puts [format "  %-20s ok   (%s passed)" $name $p] ; incr passed
    } else {
        puts [format "  %-20s FAIL (%s failed)" $name $f] ; incr failed
        lappend failedNames $name
    }
}

puts ""
puts "suites: $passed ok, $failed failed[expr {$skipped?", $skipped skipped":""}]"
if {$failed} { puts "failing: $failedNames" ; exit 1 }
exit 0
