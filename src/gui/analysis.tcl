# gui/analysis.tcl -- analysis dialogs: transient scope, AC Bode, compiled-code/netlist viewers.
# Extends ::schem::gui::App (defined in gui/app.tcl).

oo::define ::schem::gui::App {
    method TextDialog {title body {savext ""}} {
        variable ::schem::gui::T
        set w .td[incr ::schem::gui::_wincount]
        toplevel $w -bg $T(surface)
        wm title $w $title
        catch {wm geometry $w 720x520}
        label $w.h -text $title -bg $T(surface) -fg $T(ink) -anchor w \
            -font $::schem::gui::FONTTITLE -padx 14
        pack $w.h -side top -fill x -pady {12 6}
        set tf [frame $w.tf -bg $T(surface)]
        pack $tf -side top -fill both -expand 1 -padx 12
        set txt [text $tf.t -bg $T(sunken) -fg $T(ink) -bd 0 -highlightthickness 0 \
            -wrap none -padx 10 -pady 8 -font $::schem::gui::FONTMONO \
            -yscrollcommand [list $tf.sb set] -xscrollcommand [list $tf.hb set] \
            -insertbackground $T(accent)]
        scrollbar $tf.sb -orient vertical -command [list $txt yview] \
            -bg $T(edgehi) -activebackground $T(accent) -troughcolor $T(sunken) \
            -bd 0 -highlightthickness 0 -width 13
        scrollbar $tf.hb -orient horizontal -command [list $txt xview] \
            -bg $T(edgehi) -activebackground $T(accent) -troughcolor $T(sunken) \
            -bd 0 -highlightthickness 0 -width 13
        grid $txt    -row 0 -column 0 -sticky nsew
        grid $tf.sb  -row 0 -column 1 -sticky ns
        grid $tf.hb  -row 1 -column 0 -sticky ew
        grid rowconfigure $tf 0 -weight 1
        grid columnconfigure $tf 0 -weight 1
        $txt insert end $body
        $txt configure -state disabled
        # button row
        set bb [frame $w.bb -bg $T(surface)]
        pack $bb -side bottom -fill x -padx 12 -pady 10
        button $bb.close -text "Close" -command [list destroy $w] \
            -bg $T(raised) -fg $T(ink) -activebackground $T(hover) -relief flat -padx 14 -pady 5
        pack $bb.close -side right
        if {$savext ne ""} {
            button $bb.save -text "Save…" -relief flat -padx 14 -pady 5 \
                -bg $T(accent2) -fg white -activebackground $T(accent) \
                -command [my callback DialogSave $body $savext]
            pack $bb.save -side right -padx {0 8}
        }
        return $w
    }

    method DialogSave {body ext} {
        set f [tk_getSaveFile -defaultextension $ext]
        if {$f eq ""} return
        # UTF-8: exported netlists/SVG carry Ω/µ regardless of the system locale.
        set fh [open $f w] ; fconfigure $fh -encoding utf-8 ; puts $fh $body ; close $fh
        my SetStatus "Saved $f"
    }

    method TransientDialog {} {
        variable ::schem::gui::T
        set w .tr[incr ::schem::gui::_wincount]
        toplevel $w -bg $T(surface)
        wm title $w "Transient analysis"
        catch {wm geometry $w 760x520}
        # controls
        set ctl [frame $w.ctl -bg $T(surface)]
        pack $ctl -side top -fill x -padx 12 -pady 10
        label $ctl.dl -text "Duration (s)" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.dl -side left
        entry $ctl.de -bg $T(raised) -fg $T(ink) -width 8 -relief flat \
            -insertbackground $T(accent) -font $::schem::gui::FONTMONO
        $ctl.de insert 0 "0.05" ; pack $ctl.de -side left -padx {4 12}
        label $ctl.sl -text "Step (s)" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.sl -side left
        entry $ctl.se -bg $T(raised) -fg $T(ink) -width 8 -relief flat \
            -insertbackground $T(accent) -font $::schem::gui::FONTMONO
        $ctl.se insert 0 "5e-5" ; pack $ctl.se -side left -padx {4 12}
        label $ctl.nl -text "Plot node" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.nl -side left
        # node menu = every component terminal
        set terms {}
        foreach n [$S components] {
            if {[$S typeof $n] in {ground bus junction}} continue
            foreach t [$S terminals $n] { lappend terms $n.$t }
        }
        set nodevar ::schem::gui::_trnode$::schem::gui::_wincount
        set $nodevar [lindex $terms 0]
        set mb [menubutton $ctl.nb -textvariable $nodevar -bg $T(raised) -fg $T(ink) \
            -relief flat -padx 8 -pady 2 -font $::schem::gui::FONTMONO -direction below -indicatoron 0]
        pack $mb -side left -padx 4
        set nm [menu $mb.m -tearoff 0 -bg $T(raised) -fg $T(ink) -activebackground $T(accent2)]
        $mb configure -menu $nm
        foreach t $terms { $nm add command -label $t -command [list set $nodevar $t] }
        # plot canvas
        set plot [canvas $w.plot -bg $T(sunken) -highlightthickness 0]
        pack $plot -side top -fill both -expand 1 -padx 12 -pady {0 8}
        # buttons
        set bb [frame $w.bb -bg $T(surface)]
        pack $bb -side bottom -fill x -padx 12 -pady 10
        button $bb.run -text "Run ▶" -relief flat -padx 16 -pady 5 \
            -bg $T(accent2) -fg white -activebackground $T(accent) \
            -command [my callback RunTransient $ctl.de $ctl.se $nodevar $plot]
        pack $bb.run -side left
        button $bb.close -text "Close" -command [list destroy $w] \
            -bg $T(raised) -fg $T(ink) -activebackground $T(hover) -relief flat -padx 14 -pady 5
        pack $bb.close -side right
        after 60 [my callback RunTransient $ctl.de $ctl.se $nodevar $plot]
    }

    method RunTransient {de se nodevar plot} {
        variable ::schem::gui::T
        if {![winfo exists $plot]} return
        set dur [$de get] ; set dt [$se get] ; set node [set $nodevar]
        if {![string is double -strict $dur] || ![string is double -strict $dt]} {
            my SetStatus "transient: bad duration/step" ; return
        }
        if {[catch {$S run -duration $dur -dt $dt -record [list $node]} res]} {
            my SetStatus "transient error: $res" ; return
        }
        my PlotWave $plot [dict get $res t] [dict get $res $node] $node
        my SetStatus "Transient run: $node over ${dur}s" "OK"
    }

    method PlotWave {c ts vs label} {
        variable ::schem::gui::T
        $c delete all
        update idletasks
        set W [winfo width $c] ; set H [winfo height $c]
        if {$W < 50} { set W 700 } ; if {$H < 50} { set H 360 }
        set ml 54 ; set mr 16 ; set mt 16 ; set mb 28
        set t0 [lindex $ts 0] ; set t1 [lindex $ts end]
        if {$t1 <= $t0} { set t1 [expr {$t0+1}] }
        set vmin [lindex [lsort -real $vs] 0] ; set vmax [lindex [lsort -real $vs] end]
        if {$vmax-$vmin < 1e-9} { set vmin [expr {$vmin-1}] ; set vmax [expr {$vmax+1}] }
        set pad [expr {($vmax-$vmin)*0.1}] ; set vmin [expr {$vmin-$pad}] ; set vmax [expr {$vmax+$pad}]
        set sx [list apply {{t ml W mr t0 t1} {expr {$ml+($t-$t0)/($t1-$t0)*($W-$ml-$mr)}}} {} $ml $W $mr $t0 $t1]
        # helper closures via expr inline
        set xpix {{t} { upvar 1 ml ml W W mr mr t0 t0 t1 t1 ; expr {$ml+($t-$t0)/($t1-$t0)*($W-$ml-$mr)} }}
        set ypix {{v} { upvar 1 mt mt H H mb mb vmin vmin vmax vmax ; expr {$mt+($vmax-$v)/($vmax-$vmin)*($H-$mt-$mb)} }}
        # grid + axis labels
        for {set i 0} {$i <= 4} {incr i} {
            set v [expr {$vmin+($vmax-$vmin)*$i/4.0}]
            set y [apply $ypix $v]
            $c create line $ml $y [expr {$W-$mr}] $y -fill $T(edge)
            $c create text [expr {$ml-6}] $y -text [format %.2g $v] -anchor e \
                -fill $T(dim) -font $::schem::gui::FONTSM
        }
        $c create text [expr {($ml+$W-$mr)/2}] [expr {$H-8}] -text "time (s)  ·  0 → [format %.3g $t1]" \
            -fill $T(faint) -font $::schem::gui::FONTSM
        $c create text [expr {$ml+4}] [expr {$mt+2}] -text $label -anchor nw \
            -fill $T(accent) -font $::schem::gui::FONTH
        # zero line
        if {$vmin < 0 && $vmax > 0} {
            set yz [apply $ypix 0] ; $c create line $ml $yz [expr {$W-$mr}] $yz -fill $T(edgehi)
        }
        # trace
        set pts {}
        foreach t $ts v $vs { lappend pts [apply $xpix $t] [apply $ypix $v] }
        if {[llength $pts] >= 4} {
            $c create line {*}$pts -fill $T(good) -width 2 -smooth 1
        }
    }

    method CmdAcSweep {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to sweep." ; return }
        my SyncPositions
        # an AC sweep drives a battery as the small-signal source; need one
        if {[llength [lmap n [$S components] {expr {[$S typeof $n] eq "battery" ? $n : [continue]}}]] == 0} {
            my SetStatus "AC sweep needs a battery as the source." ; return
        }
        my AcSweepDialog
    }

    method AcSweepDialog {} {
        variable ::schem::gui::T
        set w .ac[incr ::schem::gui::_wincount]
        toplevel $w -bg $T(surface)
        wm title $w "AC frequency sweep"
        catch {wm geometry $w 760x540}
        set ctl [frame $w.ctl -bg $T(surface)]
        pack $ctl -side top -fill x -padx 12 -pady 10
        # from / to (decades), points/decade, output node
        foreach {lbl var def wd} {"From (Hz)" f0 1 8  "To (Hz)" f1 1e6 8  "Pts/dec" ppd 20 5} {
            label $ctl.l$var -text $lbl -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
            pack $ctl.l$var -side left
            entry $ctl.e$var -bg $T(raised) -fg $T(ink) -width $wd -relief flat \
                -insertbackground $T(accent) -font $::schem::gui::FONTMONO
            $ctl.e$var insert 0 $def ; pack $ctl.e$var -side left -padx {4 12}
        }
        label $ctl.nl -text "Output" -bg $T(surface) -fg $T(dim) -font $::schem::gui::FONTSM
        pack $ctl.nl -side left
        set terms {}
        foreach n [$S components] {
            if {[$S typeof $n] in {ground bus junction battery}} continue
            foreach t [$S terminals $n] { lappend terms $n.$t }
        }
        # also offer the source terminals, but after the signal nodes
        foreach n [$S components] {
            if {[$S typeof $n] ne "battery"} continue
            foreach t [$S terminals $n] { lappend terms $n.$t }
        }
        set nodevar ::schem::gui::_acnode$::schem::gui::_wincount
        set $nodevar [lindex $terms 0]
        set mb [menubutton $ctl.nb -textvariable $nodevar -bg $T(raised) -fg $T(ink) \
            -relief flat -padx 8 -pady 2 -font $::schem::gui::FONTMONO -direction below -indicatoron 0]
        pack $mb -side left -padx 4
        set nm [menu $mb.m -tearoff 0 -bg $T(raised) -fg $T(ink) -activebackground $T(accent2)]
        $mb configure -menu $nm
        foreach t $terms { $nm add command -label $t -command [list set $nodevar $t] }
        set plot [canvas $w.plot -bg $T(sunken) -highlightthickness 0]
        pack $plot -side top -fill both -expand 1 -padx 12 -pady {0 8}
        set bb [frame $w.bb -bg $T(surface)]
        pack $bb -side bottom -fill x -padx 12 -pady 10
        button $bb.run -text "Sweep ▶" -relief flat -padx 16 -pady 5 \
            -bg $T(accent2) -fg white -activebackground $T(accent) \
            -command [my callback RunAcSweep $ctl.ef0 $ctl.ef1 $ctl.eppd $nodevar $plot]
        pack $bb.run -side left
        button $bb.close -text "Close" -command [list destroy $w] \
            -bg $T(raised) -fg $T(ink) -activebackground $T(hover) -relief flat -padx 14 -pady 5
        pack $bb.close -side right
        after 60 [my callback RunAcSweep $ctl.ef0 $ctl.ef1 $ctl.eppd $nodevar $plot]
    }

    method RunAcSweep {ef0 ef1 eppd nodevar plot} {
        variable ::schem::gui::T
        if {![winfo exists $plot]} return
        set f0 [$ef0 get] ; set f1 [$ef1 get] ; set ppd [$eppd get] ; set node [set $nodevar]
        if {![string is double -strict $f0] || ![string is double -strict $f1] || $f0 <= 0 || $f1 <= $f0} {
            my SetStatus "AC sweep: bad frequency range" ; return
        }
        # build a log-spaced frequency list
        set decades [expr {log10($f1/$f0)}]
        set npts [expr {int($decades*$ppd)+1}]
        if {$npts < 2} { set npts 2 } ; if {$npts > 600} { set npts 600 }
        set freqs {}
        for {set i 0} {$i < $npts} {incr i} {
            lappend freqs [expr {$f0*pow(10.0,$decades*$i/($npts-1))}]
        }
        if {[catch {$S acsweep $freqs} sw]} { my SetStatus "AC sweep error: $sw" ; return }
        # magnitude (acmag already returns dB) and phase (deg) at the output node
        set mags {} ; set phs {}
        foreach f $freqs {
            set ph [$S acnode $sw $f $node]
            lappend mags [$S acmag $ph]
            lappend phs [$S acphase $ph]
        }
        my PlotBode $plot $freqs $mags $phs $node
        my SetStatus "AC sweep: |$node| over $f0–$f1 Hz" "OK"
    }

    method PlotBode {c freqs mags phs label} {
        variable ::schem::gui::T
        $c delete all
        update idletasks
        set W [winfo width $c] ; set H [winfo height $c]
        if {$W < 50} { set W 700 } ; if {$H < 50} { set H 380 }
        set ml 54 ; set mr 16 ; set mt 16 ; set mb 30 ; set gap 24
        set ph0 [expr {($H-$mt-$mb-$gap)*0.62}]   ;# magnitude pane height
        set ph1 [expr {($H-$mt-$mb-$gap)-$ph0}]   ;# phase pane height
        set f0 [lindex $freqs 0] ; set f1 [lindex $freqs end]
        set lf0 [expr {log10($f0)}] ; set lf1 [expr {log10($f1)}]
        if {$lf1 <= $lf0} { set lf1 [expr {$lf0+1}] }
        set xpix {{f} { upvar 1 ml ml W W mr mr lf0 lf0 lf1 lf1 ; expr {$ml+(log10($f)-$lf0)/($lf1-$lf0)*($W-$ml-$mr)} }}
        # magnitude pane
        set m0 [lindex [lsort -real $mags] 0] ; set m1 [lindex [lsort -real $mags] end]
        if {$m1-$m0 < 1} { set m0 [expr {$m0-1}] ; set m1 [expr {$m1+1}] }
        set pad [expr {($m1-$m0)*0.1}] ; set m0 [expr {$m0-$pad}] ; set m1 [expr {$m1+$pad}]
        set ytop $mt ; set ybot [expr {$mt+$ph0}]
        set ymag {{v} { upvar 1 ytop ytop ybot ybot m0 m0 m1 m1 ; expr {$ytop+($m1-$v)/($m1-$m0)*($ybot-$ytop)} }}
        for {set i 0} {$i <= 3} {incr i} {
            set v [expr {$m0+($m1-$m0)*$i/3.0}] ; set y [apply $ymag $v]
            $c create line $ml $y [expr {$W-$mr}] $y -fill $T(edge)
            $c create text [expr {$ml-6}] $y -text "[format %.0f $v]" -anchor e -fill $T(dim) -font $::schem::gui::FONTSM
        }
        $c create text [expr {$ml+4}] [expr {$ytop+2}] -text "|$label|  (dB)" -anchor nw -fill $T(accent) -font $::schem::gui::FONTH
        set pts {}
        foreach f $freqs v $mags { lappend pts [apply $xpix $f] [apply $ymag $v] }
        if {[llength $pts] >= 4} { $c create line {*}$pts -fill $T(good) -width 2 -smooth 1 }
        # phase pane
        set ptop [expr {$ybot+$gap}] ; set pbot [expr {$ptop+$ph1}]
        set p0 -180.0 ; set p1 180.0
        set yph {{v} { upvar 1 ptop ptop pbot pbot p0 p0 p1 p1 ; expr {$ptop+($p1-$v)/($p1-$p0)*($pbot-$ptop)} }}
        foreach v {-180 -90 0 90 180} {
            set y [apply $yph $v]
            $c create line $ml $y [expr {$W-$mr}] $y -fill [expr {$v==0 ? $T(edgehi) : $T(edge)}]
            $c create text [expr {$ml-6}] $y -text "$v" -anchor e -fill $T(dim) -font $::schem::gui::FONTSM
        }
        $c create text [expr {$ml+4}] [expr {$ptop+2}] -text "phase (°)" -anchor nw -fill $T(probe) -font $::schem::gui::FONTH
        set pts {}
        foreach f $freqs v $phs { lappend pts [apply $xpix $f] [apply $yph $v] }
        if {[llength $pts] >= 4} { $c create line {*}$pts -fill $T(probe) -width 2 }
        # x labels (decade ticks)
        for {set d [expr {int(floor($lf0))}]} {$d <= int(ceil($lf1))} {incr d} {
            set f [expr {pow(10.0,$d)}]
            if {$f < $f0 || $f > $f1} continue
            set x [apply $xpix $f]
            $c create line $x $mt $x [expr {$H-$mb}] -fill $T(edge) -dash {1 3}
            $c create text $x [expr {$H-$mb+12}] -text "[my EngHz $f]" -fill $T(dim) -font $::schem::gui::FONTSM
        }
        $c create text [expr {($ml+$W-$mr)/2}] [expr {$H-6}] -text "frequency (Hz, log)" -fill $T(faint) -font $::schem::gui::FONTSM
    }

    method EngHz {f} {
        if {$f >= 1e6} { return "[format %g [expr {$f/1e6}]]M" }
        if {$f >= 1e3} { return "[format %g [expr {$f/1e3}]]k" }
        return [format %g $f]
    }

}
