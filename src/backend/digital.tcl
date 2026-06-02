# digital.tcl -- digital backends (boolean cycle eval + Zig digital),
# split from backend.tcl.  Consumes the Circuit IR.

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
    set vcc {} ; set static {} ; set relays {} ; set buffers {} ; set unsupported {}
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
            buffer     { lappend buffers [list [dict get $e in] [dict get $e oe] [dict get $e out]] }
            meter      { lappend static [list [dict get $nd a] [dict get $nd b]] }
            protective { if {[dict get $e state] in {intact closed}} { lappend static [list [dict get $nd a] [dict get $nd b]] } }
            conductor  { lappend static [list [dict get $nd a] [dict get $nd b]] }
            default    { lappend unsupported "$nm ([dict get $e type])" }
        }
    }
    if {[llength $unsupported]} {
        return -code error "digital mode needs a relay-logic circuit; not digital: [join $unsupported {, }]"
    }
    set energized [dict create] ; set bufout [dict create]
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
        # HIGH = reachable from any supply rail (or an enabled buffer driving a
        # 1 onto the bus) through closed contacts.
        array unset high ; array set high {}
        set queue {}
        foreach v [concat $vcc [dict keys $bufout]] { if {![info exists high($v)]} { set high($v) 1 ; lappend queue $v } }
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
        # a tri-state buffer drives a 1 onto its output iff enabled and input high
        set newbo [dict create]
        foreach b $buffers {
            lassign $b in oe out
            if {[info exists high($oe)] && [info exists high($in)]} { dict set newbo $out 1 }
        }
        if {$newen eq $energized && $newbo eq $bufout} break
        set energized $newen ; set bufout $newbo
    }
    set v [dict create 0 0]
    for {set i 1} {$i <= $N} {incr i} { dict set v $i [expr {[info exists high($i)] ? 1 : 0}] }
    return $v
}

# ====================================================================
#  digseq -- the CLOCKED digital reference (sequential boolean evaluation).
# ====================================================================
#
# digref is combinational: it settles one operating point from scratch.  But
# real sequential logic -- latches, flip-flops, counters, RAM -- only behaves
# correctly when it *carries state between clock cycles*: a seal-in relay that
# was energised stays energised, a memory cell that was written keeps its word.
# That is exactly what the electrical engine's `solve` does by seeding from its
# persistent relay state (and memory cells) every solve.
#
# digseq is the digital counterpart: a *stateful* evaluator.  Given the IR for
# one cycle (the current switch positions baked in) and the prior state, it
# settles the boolean fixed point -- reachability from the supply rails AND any
# memory data-out pin driving a stored 1, relays switching, memory reading its
# addressed cell and latching a write on the rising clock edge -- then returns
# the node levels together with the new state to carry to the next cycle.  This
# mirrors the engine's solve/UpdateMemory/MemLatchClock step for step, so a
# sequential circuit clocked through digseq gives the IDENTICAL bit pattern at
# every node every cycle, at O(nets+contacts) per pass.
#
#   set st {}
#   foreach cycle {...} { ...toggle switches, recompile cir...
#       set r [digseq $cir $st] ; set st [dict get $r state] ; ... [dict get $r levels] }
#
# Returns {levels {nid -> 1/0}  state {energized .. cells .. prevclk ..}}.
proc ::schem::backend::digseq {cir {state {}}} {
    set N [dict get $cir nodes count]
    set vcc {} ; set static {} ; set relays {} ; set mems {} ; set buffers {} ; set unsupported {}
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
                lappend relays [list $nm [dict get $cn c1] [dict get $cn c2] [dict get $kn com] [dict get $kn no] [dict get $kn nc]]
            }
            buffer     { lappend buffers [list [dict get $e in] [dict get $e oe] [dict get $e out]] }
            meter      { lappend static [list [dict get $nd a] [dict get $nd b]] }
            protective { if {[dict get $e state] in {intact closed}} { lappend static [list [dict get $nd a] [dict get $nd b]] } }
            conductor  { lappend static [list [dict get $nd a] [dict get $nd b]] }
            memory {
                set mv [dict get $e move]
                lappend mems [list [dict get $e name] [dict get $e abits] [dict get $e dbits] \
                    [dict get $e mode] [dict get $e address] [dict get $e di] [dict get $e do] \
                    [dict get $e we] [dict get $e clk] \
                    [expr {$mv ne "" ? [dict get $mv left] : 0}] \
                    [expr {$mv ne "" ? [dict get $mv right] : 0}]]
            }
            default    { lappend unsupported "$nm ([dict get $e type])" }
        }
    }
    if {[llength $unsupported]} {
        return -code error "clocked digital mode needs a digital (relay/memory) circuit; not digital: [join $unsupported {, }]"
    }
    # Carry persistent state across cycles (the seal-in latch and memory cells).
    set energized [expr {[dict exists $state energized] ? [dict get $state energized] : [dict create]}]
    set cells     [expr {[dict exists $state cells]     ? [dict get $state cells]     : [dict create]}]
    set prevclk   [expr {[dict exists $state prevclk]   ? [dict get $state prevclk]   : [dict create]}]
    set heads     [expr {[dict exists $state heads]     ? [dict get $state heads]     : [dict create]}]
    set bufout [dict create]      ;# tri-state buffer outputs driving a 1 this cycle

    set memout [dict create]      ;# word each memory drives this cycle (fresh, recomputed)
    set memwrote [dict create]    ;# a memory writes at most once per cycle (one edge)
    array set high {}
    for {set iter 0} {$iter < 1000} {incr iter} {
        # closed-edge adjacency for the current relay state
        array unset adj ; array set adj {}
        foreach e $static {
            lappend adj([lindex $e 0]) [lindex $e 1] ; lappend adj([lindex $e 1]) [lindex $e 0]
        }
        foreach r $relays {
            lassign $r nm c1 c2 com no nc
            set t [expr {[dict exists $energized $nm] ? $no : $nc}]
            lappend adj($com) $t ; lappend adj($t) $com
        }
        # HIGH sources: the supply rails, plus any memory data-out pin currently
        # driving a stored 1 (a data-out at 1 is a HIGH driver, like a rail).
        set sources $vcc
        foreach m $mems {
            lassign $m nm ab db mode addr di do we clk
            set word [expr {[dict exists $memout $nm] ? [dict get $memout $nm] : [lrepeat $db 0]}]
            for {set i 0} {$i < $db} {incr i} {
                if {[lindex $word $i]} { lappend sources [lindex $do $i] }
            }
        }
        lappend sources {*}[dict keys $bufout]   ;# enabled tri-state buffers driving a 1
        # reachability: HIGH = reachable from a source through closed contacts
        array unset high ; array set high {}
        set queue {}
        foreach v $sources { if {![info exists high($v)]} { set high($v) 1 ; lappend queue $v } }
        while {[llength $queue]} {
            set cur [lindex $queue 0] ; set queue [lrange $queue 1 end]
            foreach nb [expr {[info exists adj($cur)] ? $adj($cur) : {}}] {
                if {![info exists high($nb)]} { set high($nb) 1 ; lappend queue $nb }
            }
        }
        if {[info exists high(0)]} { unset high(0) }
        set changed 0
        # relays: a coil energises across a HIGH-to-LOW differential
        set newen [dict create]
        foreach r $relays {
            lassign $r nm c1 c2 com no nc
            if {[info exists high($c1)] != [info exists high($c2)]} { dict set newen $nm 1 }
        }
        set relCh [expr {$newen ne $energized}]
        if {$relCh} { set energized $newen ; set changed 1 }
        # tri-state buffers: drive a 1 onto the output iff enabled and input high
        set newbo [dict create]
        foreach b $buffers {
            lassign $b in oe out
            if {[info exists high($oe)] && [info exists high($in)]} { dict set newbo $out 1 }
        }
        set bufCh [expr {$newbo ne $bufout}]
        if {$bufCh} { set bufout $newbo ; set changed 1 }
        # A clocked write must sample the *settled* address/data: only let it
        # fire once relays and tri-state buffers are stable this pass, exactly
        # as the engine's solve gates it -- otherwise a bus-driven address/data
        # would latch its pre-settled value.  The combinational read runs always.
        set allowWrite [expr {!$relCh && !$bufCh}]
        # memory: read the selected cell, latch a write on the rising clock edge.
        # RAM decodes its address pins; a tape uses its (persistent) head, which
        # steps LEFT/RIGHT on the edge -- so its store is unbounded, never 2^N.
        foreach m $mems {
            lassign $m nm ab db mode addr di do we clk left right
            if {$mode eq "tape"} {
                set idx [expr {[dict exists $heads $nm] ? [dict get $heads $nm] : 0}]
            } else {
                set idx 0
                for {set i 0} {$i < $ab} {incr i} { if {[info exists high([lindex $addr $i])]} { set idx [expr {$idx | (1 << $i)}] } }
            }
            set clkH [info exists high($clk)] ; set weH [info exists high($we)]
            set pc [expr {[dict exists $prevclk $nm] ? [dict get $prevclk $nm] : 0}]
            if {$allowWrite && ![dict exists $memwrote $nm] && $clkH && !$pc} {
                if {$weH} {
                    set d {}
                    for {set i 0} {$i < $db} {incr i} { lappend d [expr {[info exists high([lindex $di $i])] ? 1 : 0}] }
                    dict set cells $nm $idx $d ; set changed 1
                }
                if {$mode eq "tape"} {
                    if {[info exists high($right)]} { incr idx }
                    if {[info exists high($left)]}  { incr idx -1 }
                    dict set heads $nm $idx
                }
                dict set memwrote $nm 1
            }
            set word [expr {[dict exists $cells $nm $idx] ? [dict get $cells $nm $idx] : [lrepeat $db 0]}]
            if {![dict exists $memout $nm] || [dict get $memout $nm] ne $word} {
                dict set memout $nm $word ; set changed 1
            }
        }
        if {!$changed} break
    }
    # latch each memory's clock level for next cycle's rising-edge detection
    foreach m $mems {
        lassign $m nm ab db mode addr di do we clk
        dict set prevclk $nm [expr {[info exists high($clk)] ? 1 : 0}]
    }
    set levels [dict create 0 0]
    for {set i 1} {$i <= $N} {incr i} { dict set levels $i [expr {[info exists high($i)] ? 1 : 0}] }
    return [dict create levels $levels \
        state [dict create energized $energized cells $cells prevclk $prevclk heads $heads]]
}

# ====================================================================
#  Zig DIGITAL backend -- emit a boolean cycle evaluator.
# ====================================================================
#
# The digitally-optimised counterpart to the literal (MNA) Zig backend, and
# the transcription of digref.  For a provably-digital relay-logic circuit it
# emits a Zig program that settles the logic as booleans -- a net is HIGH iff
# a closed-contact path reaches a supply rail (reachability), relays switch on
# a fixed point -- and prints each node's logic level.  Identical HIGH/LOW
# results to the literal solve (verified: emit both, run both, diff), at
# O(nets+contacts) per pass instead of an O(n^x) matrix factorisation.
proc ::schem::backend::ZigDigital {cir} {
    set N [dict get $cir nodes count]
    set vcc {} ; set se_a {} ; set se_b {} ; set unsupported {}
    set r_c1 {} ; set r_c2 {} ; set r_com {} ; set r_no {} ; set r_nc {}
    set b_in {} ; set b_oe {} ; set b_out {}
    foreach e [dict get $cir elements] {
        set nm [dict get $e name]
        if {[dict exists $e nodes]} { set nd [dict get $e nodes] }
        switch [dict get $e class] {
            source {
                if {[dict get $nd neg] == 0} { lappend vcc [dict get $nd pos] } \
                else { lappend unsupported "$nm (supply not referenced to ground)" }
            }
            switch    { if {[dict get $e state] in {closed pressed}} { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] } }
            conductance { }
            relay {
                set cn [dict get $e coil nodes] ; set kn [dict get $e contact nodes]
                lappend r_c1 [dict get $cn c1] ; lappend r_c2 [dict get $cn c2]
                lappend r_com [dict get $kn com] ; lappend r_no [dict get $kn no] ; lappend r_nc [dict get $kn nc]
            }
            buffer     { lappend b_in [dict get $e in] ; lappend b_oe [dict get $e oe] ; lappend b_out [dict get $e out] }
            meter      { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] }
            protective { if {[dict get $e state] in {intact closed}} { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] } }
            conductor  { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] }
            default    { lappend unsupported "$nm ([dict get $e type])" }
        }
    }
    if {[llength $unsupported]} {
        return -code error "zig -digital needs a relay-logic circuit; not digital: [join $unsupported {, }]"
    }
    set NR [llength $r_c1] ; set NSE [llength $se_a] ; set NV [llength $vcc] ; set NB [llength $b_in]
    set name [dict get $cir name]
    proc A3 {ty vals} { return "\[[llength $vals]\]$ty{[join $vals {, }]}" }

    set S {}
    lappend S "// Generated by Schem -- DIGITAL evaluation of \"$name\""
    lappend S "// Derived from the Circuit IR; the .schem schematic is the source."
    lappend S "// $N node(s), $NR relay(s), $NB tri-state buffer(s); boolean cycle eval (verified == the electrical solve)."
    lappend S "const std = @import(\"std\");"
    lappend S "const N: usize = $N; const NR: usize = $NR; const NSE: usize = $NSE; const NV: usize = $NV; const NB: usize = $NB;"
    if {$NV}  { lappend S "const vcc = [A3 usize $vcc];" }
    if {$NSE} { lappend S "const se_a = [A3 usize $se_a]; const se_b = [A3 usize $se_b];" }
    if {$NB}  { lappend S "const b_in = [A3 usize $b_in]; const b_oe = [A3 usize $b_oe]; const b_out = [A3 usize $b_out];" }
    if {$NR}  {
        lappend S "const r_c1 = [A3 usize $r_c1]; const r_c2 = [A3 usize $r_c2];"
        lappend S "const r_com = [A3 usize $r_com]; const r_no = [A3 usize $r_no]; const r_nc = [A3 usize $r_nc];"
        lappend S "var energized = \[_\]bool{false} ** NR;"
    }
    lappend S "var high = \[_\]bool{false} ** (N + 1);   // node -> HIGH; index 0 = ground (always LOW)"
    lappend S ""
    lappend S "fn relax(a: usize, b: usize) bool {       // propagate HIGH across a closed edge"
    lappend S "    if (high\[a\] and !high\[b\] and b != 0) { high\[b\] = true; return true; }"
    lappend S "    if (high\[b\] and !high\[a\] and a != 0) { high\[a\] = true; return true; }"
    lappend S "    return false;"
    lappend S "}"
    lappend S "fn reach() void {                          // nets reachable from a rail are HIGH"
    lappend S "    for (&high) |*h| h.* = false;"
    if {$NV}  { lappend S "    for (vcc) |v| high\[v\] = true;" }
    lappend S "    var changed = true;"
    lappend S "    while (changed) {"
    lappend S "        changed = false;"
    if {$NSE} { lappend S "        { var e: usize = 0; while (e < NSE) : (e += 1) { if (relax(se_a\[e\], se_b\[e\])) changed = true; } }" }
    if {$NR}  {
        lappend S "        { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "            const t = if (energized\[r\]) r_no\[r\] else r_nc\[r\];"
        lappend S "            if (relax(r_com\[r\], t)) changed = true;"
        lappend S "        } }"
    }
    if {$NB}  {
        lappend S "        { var b: usize = 0; while (b < NB) : (b += 1) {   // tri-state: drive out=1 when enabled and in=1"
        lappend S "            if (high\[b_oe\[b\]\] and high\[b_in\[b\]\] and !high\[b_out\[b\]\] and b_out\[b\] != 0) { high\[b_out\[b\]\] = true; changed = true; }"
        lappend S "        } }"
    }
    lappend S "    }"
    lappend S "    high\[0\] = false;"
    lappend S "}"
    lappend S "fn settle() void {                         // fixed point over relay state"
    if {$NR} {
        lappend S "    var pass: usize = 0;"
        lappend S "    while (pass < 1000) : (pass += 1) {"
        lappend S "        reach();"
        lappend S "        var changed = false;"
        lappend S "        { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "            const en = high\[r_c1\[r\]\] != high\[r_c2\[r\]\];"
        lappend S "            if (en != energized\[r\]) { energized\[r\] = en; changed = true; }"
        lappend S "        } }"
        lappend S "        if (!changed) break;"
        lappend S "    }"
    } else {
        # no relays: buffers/memory-out settle entirely within reach()
        lappend S "    reach();"
    }
    lappend S "}"
    lappend S ""
    lappend S "pub fn main() !void {"
    lappend S "    const stdout = std.io.getStdOut().writer();"
    lappend S "    settle();"
    lappend S "    try stdout.print(\"digital levels of \\\"$name\\\" (1=HIGH, 0=LOW)\\n\", .{});"
    dict for {nid terms} [dict get $cir nodes map] {
        if {$nid == 0} continue
        lappend S "    // N$nid : [join $terms { }]"
        lappend S "    try stdout.print(\"  N{d} = {d}\\n\", .{ $nid, @intFromBool(high\[$nid\]) });"
    }
    lappend S "}"
    return [join $S \n]
}

# ====================================================================
#  Zig CLOCKED DIGITAL backend -- emit a sequential boolean evaluator.
# ====================================================================
#
# The compiled counterpart of digseq: a digital program that carries relay and
# memory state across clock cycles and runs a compiled-in input schedule.
# Switches are runtime-mutable (the panel/clock), driven by -events keyed on
# the cycle number ({cycle {op SW} ...}); each cycle it applies that cycle's
# operations, settles the boolean fixed point (reachability from the rails and
# from any memory data-out driving a stored 1, relays switching, memory reading
# its cell and latching a write on the rising clock edge -- exactly digseq's
# step), then prints every node's level.  Run the same schedule through digseq
# and the engine and the bit pattern is identical every cycle, at
# O(nets+contacts) per pass -- sequential logic at native speed.
proc ::schem::backend::ZigDigitalSeq {cir cycles {events {}}} {
    set N [dict get $cir nodes count]
    set vcc {} ; set se_a {} ; set se_b {} ; set unsupported {}
    set sw_a {} ; set sw_b {} ; set sw_init {} ; set swidx [dict create]
    set r_c1 {} ; set r_c2 {} ; set r_com {} ; set r_no {} ; set r_nc {}
    set b_in {} ; set b_oe {} ; set b_out {}
    set mems {}
    foreach e [dict get $cir elements] {
        set nm [dict get $e name]
        if {[dict exists $e nodes]} { set nd [dict get $e nodes] }
        switch [dict get $e class] {
            source {
                if {[dict get $nd neg] == 0} { lappend vcc [dict get $nd pos] } \
                else { lappend unsupported "$nm (supply not referenced to ground)" }
            }
            switch {
                dict set swidx $nm [llength $sw_a]
                lappend sw_a [dict get $nd a] ; lappend sw_b [dict get $nd b]
                lappend sw_init [expr {[dict get $e state] in {closed pressed} ? "true" : "false"}]
            }
            conductance { }
            relay {
                set cn [dict get $e coil nodes] ; set kn [dict get $e contact nodes]
                lappend r_c1 [dict get $cn c1] ; lappend r_c2 [dict get $cn c2]
                lappend r_com [dict get $kn com] ; lappend r_no [dict get $kn no] ; lappend r_nc [dict get $kn nc]
            }
            buffer     { lappend b_in [dict get $e in] ; lappend b_oe [dict get $e oe] ; lappend b_out [dict get $e out] }
            meter      { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] }
            protective { if {[dict get $e state] in {intact closed}} { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] } }
            conductor  { lappend se_a [dict get $nd a] ; lappend se_b [dict get $nd b] }
            memory     { lappend mems $e }
            default    { lappend unsupported "$nm ([dict get $e type])" }
        }
    }
    if {[llength $unsupported]} {
        return -code error "clocked digital mode needs a digital (relay/memory) circuit; not digital: [join $unsupported {, }]"
    }
    set NR [llength $r_c1] ; set NSE [llength $se_a] ; set NV [llength $vcc] ; set NS [llength $sw_a] ; set NB [llength $b_in]
    set name [dict get $cir name]
    set arr {{ty vals} {return "\[[llength $vals]\]$ty{[join $vals {, }]}"}}

    # compile -events ({cycle {op SW} ...}) into per-cycle switch assignments
    set actions {}
    foreach {cy op} $events {
        lassign $op verb swname
        if {![dict exists $swidx $swname]} continue
        lappend actions [list [expr {int($cy)}] [dict get $swidx $swname] \
            [expr {$verb in {close press} ? "true" : "false"}] $verb $swname]
    }

    set S {}
    lappend S "// Generated by Schem -- CLOCKED DIGITAL evaluation of \"$name\""
    lappend S "// Derived from the Circuit IR; the .schem schematic is the source."
    lappend S "// $N node(s), $NR relay(s), $NB tri-state buffer(s), [llength $mems] memory(ies); $cycles clock cycle(s)."
    lappend S "// Sequential boolean eval, state carried across cycles (verified == the engine)."
    lappend S "const std = @import(\"std\");"
    lappend S "const N: usize = $N; const NR: usize = $NR; const NSE: usize = $NSE; const NV: usize = $NV; const NS: usize = $NS; const NB: usize = $NB;"
    lappend S "const CYCLES: usize = $cycles;"
    if {$NV}  { lappend S "const vcc = [apply $arr usize $vcc];" }
    if {$NSE} { lappend S "const se_a = [apply $arr usize $se_a]; const se_b = [apply $arr usize $se_b];" }
    if {$NB}  { lappend S "const b_in = [apply $arr usize $b_in]; const b_oe = [apply $arr usize $b_oe]; const b_out = [apply $arr usize $b_out];" }
    if {$NS}  {
        lappend S "const sw_a = [apply $arr usize $sw_a]; const sw_b = [apply $arr usize $sw_b];"
        lappend S "var sw_state = \[NS\]bool{[join $sw_init {, }]};"
    }
    if {$NR}  {
        lappend S "const r_c1 = [apply $arr usize $r_c1]; const r_c2 = [apply $arr usize $r_c2];"
        lappend S "const r_com = [apply $arr usize $r_com]; const r_no = [apply $arr usize $r_no]; const r_nc = [apply $arr usize $r_nc];"
        lappend S "var energized = \[_\]bool{false} ** NR;"
    }
    # per-memory persistent storage (unrolled: widths are known at emit time).
    # RAM: 2^abits cells.  Tape: a window of 2*CYCLES+1 cells with the head at
    # the centre -- in N cycles the head moves at most N from the origin, so this
    # bounded window faithfully compiles any N-cycle run of the unbounded tape.
    set mi 0
    foreach e $mems {
        set db [dict get $e dbits]
        if {[dict get $e mode] eq "tape"} {
            set sz [expr {2*$cycles + 1}]
            lappend S "// memory [dict get $e name]: tape, $db bits, $sz-cell window (head at centre)"
            lappend S "var m${mi}_cells = \[_\]\[$db\]bool{\[_\]bool{false} ** $db} ** $sz;"
            lappend S "var m${mi}_head: usize = $cycles;"
        } else {
            set sz [expr {1 << [dict get $e abits]}]
            lappend S "// memory [dict get $e name]: $sz words x $db bits, mode ram"
            lappend S "var m${mi}_cells = \[_\]\[$db\]bool{\[_\]bool{false} ** $db} ** $sz;"
        }
        lappend S "var m${mi}_out = \[_\]bool{false} ** $db;"
        lappend S "var m${mi}_prevclk: bool = false;"
        lappend S "var m${mi}_wrote: bool = false;"
        incr mi
    }
    lappend S "var high = \[_\]bool{false} ** (N + 1);"
    lappend S ""
    lappend S "fn relax(a: usize, b: usize) bool {"
    lappend S "    if (high\[a\] and !high\[b\] and b != 0) { high\[b\] = true; return true; }"
    lappend S "    if (high\[b\] and !high\[a\] and a != 0) { high\[a\] = true; return true; }"
    lappend S "    return false;"
    lappend S "}"
    lappend S "fn reach() void {"
    lappend S "    for (&high) |*h| h.* = false;"
    if {$NV}  { lappend S "    for (vcc) |v| high\[v\] = true;" }
    # seed from memory data-out pins currently driving a stored 1
    set mi 0
    foreach e $mems {
        set db [dict get $e dbits] ; set do [dict get $e do]
        for {set i 0} {$i < $db} {incr i} {
            lappend S "    if (m${mi}_out\[$i\]) high\[[lindex $do $i]\] = true;"
        }
        incr mi
    }
    lappend S "    var changed = true;"
    lappend S "    while (changed) {"
    lappend S "        changed = false;"
    if {$NSE} { lappend S "        { var e: usize = 0; while (e < NSE) : (e += 1) { if (relax(se_a\[e\], se_b\[e\])) changed = true; } }" }
    if {$NS}  { lappend S "        { var e: usize = 0; while (e < NS) : (e += 1) { if (sw_state\[e\]) { if (relax(sw_a\[e\], sw_b\[e\])) changed = true; } } }" }
    if {$NR}  {
        lappend S "        { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "            const t = if (energized\[r\]) r_no\[r\] else r_nc\[r\];"
        lappend S "            if (relax(r_com\[r\], t)) changed = true;"
        lappend S "        } }"
    }
    if {$NB}  {
        lappend S "        { var b: usize = 0; while (b < NB) : (b += 1) {   // tri-state: drive out=1 when enabled and in=1"
        lappend S "            if (high\[b_oe\[b\]\] and high\[b_in\[b\]\] and !high\[b_out\[b\]\] and b_out\[b\] != 0) { high\[b_out\[b\]\] = true; changed = true; }"
        lappend S "        } }"
    }
    # data-out pins driving 1 are sources too: re-assert them inside the loop so
    # newly-decoded reads propagate without waiting for the next reach()
    set mi 0
    foreach e $mems {
        set db [dict get $e dbits] ; set do [dict get $e do]
        for {set i 0} {$i < $db} {incr i} {
            lappend S "        if (m${mi}_out\[$i\] and !high\[[lindex $do $i]\] and [lindex $do $i] != 0) { high\[[lindex $do $i]\] = true; changed = true; }"
        }
        incr mi
    }
    lappend S "    }"
    lappend S "    high\[0\] = false;"
    lappend S "}"
    lappend S "fn settle() void {"
    lappend S "    var pass: usize = 0;"
    lappend S "    while (pass < 1000) : (pass += 1) {"
    lappend S "        reach();"
    lappend S "        var changed = false;"
    lappend S "        _ = &changed;   // (buffers/reads settle within reach(); relays/memory may set this)"
    if {$NR} {
        lappend S "        { var r: usize = 0; while (r < NR) : (r += 1) {"
        lappend S "            const en = high\[r_c1\[r\]\] != high\[r_c2\[r\]\];"
        lappend S "            if (en != energized\[r\]) { energized\[r\] = en; changed = true; }"
        lappend S "        } }"
    }
    # A clocked write must sample the *settled* address/data: defer it until the
    # relays are stable this pass (buffers already settle inside reach()), so a
    # bus-driven address/data is not latched at its pre-settled value -- the same
    # gate the engine's solve and digseq apply.  Emitted only when memory exists.
    if {[llength $mems]} { lappend S "        const relays_stable = !changed;" }
    # per-memory read/write inside the fixed point (digseq's UpdateMemory)
    set mi 0
    foreach e $mems {
        set ab [dict get $e abits] ; set db [dict get $e dbits]
        set addr [dict get $e address] ; set di [dict get $e di] ; set do [dict get $e do]
        set we [dict get $e we] ; set clk [dict get $e clk]
        if {[dict get $e mode] eq "tape"} {
            set mv [dict get $e move]
            lappend S "        { var addr: usize = m${mi}_head;"
            lappend S "          const clkH = high\[$clk\]; const weH = high\[$we\];"
            lappend S "          if (relays_stable and !m${mi}_wrote and clkH and !m${mi}_prevclk) {"
            lappend S "              if (weH) {"
            for {set i 0} {$i < $db} {incr i} { lappend S "                  m${mi}_cells\[addr\]\[$i\] = high\[[lindex $di $i]\];" }
            lappend S "              }"
            lappend S "              if (high\[[dict get $mv right]\]) m${mi}_head += 1;"
            lappend S "              if (high\[[dict get $mv left]\]) m${mi}_head -= 1;"
            lappend S "              addr = m${mi}_head;"
            lappend S "              m${mi}_wrote = true; changed = true;"
            lappend S "          }"
            for {set i 0} {$i < $db} {incr i} {
                lappend S "          if (m${mi}_out\[$i\] != m${mi}_cells\[addr\]\[$i\]) { m${mi}_out\[$i\] = m${mi}_cells\[addr\]\[$i\]; changed = true; }"
            }
            lappend S "        }"
        } else {
            lappend S "        { var addr: usize = 0;"
            for {set i 0} {$i < $ab} {incr i} { lappend S "          if (high\[[lindex $addr $i]\]) addr |= [expr {1 << $i}];" }
            lappend S "          const clkH = high\[$clk\]; const weH = high\[$we\];"
            lappend S "          if (relays_stable and !m${mi}_wrote and clkH and weH and !m${mi}_prevclk) {"
            for {set i 0} {$i < $db} {incr i} { lappend S "              m${mi}_cells\[addr\]\[$i\] = high\[[lindex $di $i]\];" }
            lappend S "              m${mi}_wrote = true; changed = true;"
            lappend S "          }"
            for {set i 0} {$i < $db} {incr i} {
                lappend S "          if (m${mi}_out\[$i\] != m${mi}_cells\[addr\]\[$i\]) { m${mi}_out\[$i\] = m${mi}_cells\[addr\]\[$i\]; changed = true; }"
            }
            lappend S "        }"
        }
        incr mi
    }
    lappend S "        if (!changed) break;"
    lappend S "    }"
    # latch each memory's clock level for next cycle's edge detection
    set mi 0
    foreach e $mems { lappend S "    m${mi}_prevclk = high\[[dict get $e clk]\];" ; incr mi }
    lappend S "}"
    lappend S ""
    lappend S "pub fn main() !void {"
    lappend S "    const stdout = std.io.getStdOut().writer();"
    lappend S "    try stdout.print(\"clocked digital \\\"$name\\\" (1=HIGH, 0=LOW), $cycles cycle(s)\\n\", .{});"
    lappend S "    var cycle: usize = 0;"
    lappend S "    while (cycle < CYCLES) : (cycle += 1) {"
    if {[llength $actions]} {
        lappend S "        // timed stimulus (-events): operate the panel each cycle"
        foreach act [lsort -integer -index 0 $actions] {
            lassign $act cy si b verb swname
            lappend S "        if (cycle == $cy) sw_state\[$si\] = $b; // $verb $swname"
        }
    }
    set mi 0
    foreach e $mems { lappend S "        m${mi}_wrote = false;" ; incr mi }
    lappend S "        settle();"
    lappend S "        try stdout.print(\"cycle {d}:\", .{cycle});"
    for {set i 1} {$i <= $N} {incr i} {
        lappend S "        try stdout.print(\" N$i={d}\", .{@intFromBool(high\[$i\])});"
    }
    lappend S "        try stdout.print(\"\\n\", .{});"
    lappend S "    }"
    lappend S "}"
    return [join $S \n]
}
