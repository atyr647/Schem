#!/usr/bin/env tclsh
# test_bombe.tcl -- the Enigma oracle and the Turing bombe.
#
# These assert the whole chain: a historically exact Enigma (canonical test
# vectors + the double-step anomaly), the scrambler involution the bombe rides
# on, the menu/closure that finds a stop, a full break that recovers a secret
# key, the bombe realised as a Schem schematic whose own continuity lights a
# stop lamp, and -- when a Zig compiler is available -- the compiled scan
# agreeing stop-for-stop with the interpreted one.
#
#   tclsh tests/test_bombe.tcl
set here [file dirname [file normalize [info script]]]
source [file join $here .. lib enigma.tcl]
source [file join $here .. lib bombe.tcl]
source [file join $here .. src schem.tcl]
source [file join $here .. lib bombe_schem.tcl]
source [file join $here .. lib bombe_zig.tcl]

set ::T 0 ; set ::F 0
proc ok {name cond} {
    if {[uplevel 1 [list expr $cond]]} { incr ::T ; puts "ok   - $name" } \
    else { incr ::F ; puts "FAIL - $name" }
}
proc section {t} { puts "\n# $t" }

# ====================================================================
section "Enigma oracle -- historical correctness"
# ====================================================================
proc enc {pos text {wheels {I II III}} {rings AAA} {refl B} {plug ""}} {
    set m [::enigma::new -wheels $wheels -rings $rings -pos $pos -reflector $refl \
        -plug [::enigma::plugboard $plug]]
    return [::enigma::encipher $m $text]
}
ok "canonical AAAAA -> BDZGO"        {[enc AAA AAAAA] eq "BDZGO"}
ok "26 A's -> known string"          {[enc AAA [string repeat A 26]] eq \
                                      "BDZGOWCXLTKSBTMCDLPBMUQOFX"}
ok "reciprocal: decipher = plaintext" {[enc AAA [enc AAA HELLOWORLD]] eq "HELLOWORLD"}
ok "no letter enciphers to itself"   {[string first H [enc QER [string repeat H 50]]] < 0}

# double-stepping window sequence ADV AEW BFX BFY BFZ
set m [::enigma::new -wheels {I II III} -rings AAA -pos ADU]
set seq {}
for {set i 0} {$i < 5} {incr i} {
    ::enigma::Step m
    lassign [dict get $m pos] L M R
    lappend seq "[::enigma::chr $L][::enigma::chr $M][::enigma::chr $R]"
}
ok "double-step ADV AEW BFX BFY BFZ" {$seq eq {ADV AEW BFX BFY BFZ}}

# plugboard is a reciprocal swap and is applied: A enciphers to B with no
# steckers, so plugging B-Q must swap that output B to Q.
ok "stecker BQ swaps the output"     {[enc AAA A {I II III} AAA B "BQ"] eq "Q"}
ok "no-stecker baseline is B"        {[enc AAA A] eq "B"}

# ====================================================================
section "Scrambler -- the involution the bombe rides on"
# ====================================================================
set P [::enigma::scrambler {I II III} AAA {0 0 0} B]
ok "scrambler is an involution"      {[apply {{P} {
    for {set i 0} {$i < 26} {incr i} {
        set j [::enigma::ord [string index $P $i]]
        if {[::enigma::ord [string index $P $j]] != $i} { return 0 }
        if {$j == $i} { return 0 }   ;# reflector: no fixed points
    }
    return 1 }} $P]}

# ====================================================================
section "Break a real message -- recover the secret key"
# ====================================================================
set wheels {I II III} ; set rings AAA ; set refl B
set SECRET QER
set plain  "WETTERVORHERSAGEBERLIN"
set mm [::enigma::new -wheels $wheels -rings $rings -pos $SECRET -reflector $refl]
set cipher [::enigma::encipher $mm $plain]
set edges  [::bombe::menu [string range $plain 0 15] [string range $cipher 0 15]]

ok "menu rejects self-encipher crib" {[catch {::bombe::menu AB AB}]}
ok "central test letter is busiest"  {[::bombe::central $edges] eq "E"}

# closure: true ground -> single live wire; wrong ground -> all 26
set true_perms [::bombe::scramblerPerms $edges $wheels $rings {16 4 17} $refl]
ok "true ground -> single live wire" {[llength [::bombe::closure $edges $true_perms E [::enigma::ord E]]] == 1}
set wrong_perms [::bombe::scramblerPerms $edges $wheels $rings {0 0 0} $refl]
ok "wrong ground -> register floods" {[llength [::bombe::closure $edges $wrong_perms E [::enigma::ord E]]] == 26}

# the stop set contains the secret key, and the key decrypts to the plaintext
set hits [::bombe::scan $edges $wheels $rings $refl]
set grounds [lmap h $hits { lindex $h 0 }]
ok "scan recovers secret key QER"    {"QER" in $grounds}
set dec [::enigma::encipher [::enigma::new -wheels $wheels -rings $rings -pos QER -reflector $refl] $cipher]
ok "recovered key decrypts message"  {$dec eq $plain}
ok "false stops decrypt to garbage"  {[apply {{wheels rings refl cipher plain grounds} {
    foreach g $grounds {
        if {$g eq "QER"} continue
        set d [::enigma::encipher [::enigma::new -wheels $wheels -rings $rings -pos $g -reflector $refl] $cipher]
        if {$d eq $plain} continue   ;# an equivalent key is allowed
        if {[regexp {WETTER} $d]} { return 0 }
    }
    return 1 }} $wheels $rings $refl $cipher $plain $grounds]}

# ====================================================================
section "The bombe as a Schem schematic -- continuity lights the stop"
# ====================================================================
set s [::bombe::build $edges $true_perms E [::enigma::ord E] b_true]
::bombe::addLamps $s E
$s solve
ok "schematic true ground: 1 live"   {[llength [::bombe::liveWires $s]] == 1}
ok "schematic true ground: 1 lamp"   {[llength [::bombe::litLamps $s]] == 1}
ok "stop lamp names the stecker (E)" {[::bombe::litLamps $s] eq [list [::enigma::ord E]]}
ok "no faults in the bombe board"    {[llength [$s faults]] == 0}
ok "board is a real circuit (>400 parts)" {[llength [$s components]] > 400}

set s2 [::bombe::build $edges $wrong_perms E [::enigma::ord E] b_wrong]
::bombe::addLamps $s2 E
$s2 solve
ok "schematic wrong ground: no stop lamp" {[llength [::bombe::litLamps $s2]] == 0}

# schematic agrees with the union-find closure at the true ground
ok "schematic live == closure live"  {[::bombe::liveWires $s] eq \
                                      [::bombe::closure $edges $true_perms E [::enigma::ord E]]}

# ====================================================================
section "Compiled scan (Zig) agrees with the model -- if zig is present"
# ====================================================================
proc zigExe {} {
    if {[info exists ::env(SCHEM_ZIG)] && [file executable $::env(SCHEM_ZIG)]} {
        return $::env(SCHEM_ZIG)
    }
    set p [auto_execok zig] ; if {$p ne ""} { return $p }
    foreach c [glob -nocomplain /tmp/zig-*/zig] { if {[file executable $c]} { return $c } }
    return ""
}
set zig [zigExe]
if {$zig eq ""} {
    puts "ok   - (skipped: no zig compiler; set SCHEM_ZIG to enable)"
    incr ::T
} else {
    set src [::bombe::emitZig $edges $wheels $rings $refl E]
    set zf [file join [file dirname [info script]] .. ztmp[pid].zig]
    set fh [open $zf w] ; puts $fh $src ; close $fh
    set out [exec {*}$zig run $zf]
    file delete $zf
    set zgrounds {}
    foreach line [split $out \n] {
        if {[regexp {STOP ([A-Z]{3})} $line -> g]} { lappend zgrounds $g }
    }
    ok "Zig scan finds the same stops"  {[lsort $zgrounds] eq [lsort $grounds]}
    ok "Zig scan recovers QER"          {"QER" in $zgrounds}
}

# --------------------------------------------------------------------
puts "\n$::T passed, $::F failed"
exit [expr {$::F > 0}]
