# gui/commands.tcl -- menu/command handlers: file, edit, simulate, manufacture.
# Extends ::schem::gui::App (defined in gui/app.tcl).

oo::define ::schem::gui::App {
    method Cmd {what args} {
        switch -- $what {
            new        { my CmdNew }
            open       { my CmdOpen }
            save       { my CmdSave }
            saveas     { my CmdSaveAs }
            export_svg { my CmdExportSvg }
            export_pcb { my CmdExportPcb }
            quit       { my CmdQuit }
            delete     { my CmdDelete }
            rotate     { my CmdRotate }
            clear      { my CmdClear }
            togglestd  { set Std [expr {$Std eq "ansi" ? "iec" : "ansi"}] ; my DrawToolbar ; my PopulateParts ; my Redraw ; my SetStatus "symbols: $Std" }
            fit        { my Redraw }
            solve      { my CmdSolve }
            transient  { my CmdTransient }
            acsweep    { my CmdAcSweep }
            clearresults { set Result none ; my Redraw ; my SetStatus "results cleared" }
            review     { my CmdReview }
            validate   { my CmdValidate }
            netlist    { my CmdNetlist }
            compile    { my CmdCompile }
            fitall     { my CmdFitAll }
            zoomin     { my ZoomIn }
            zoomout    { my ZoomOut }
            zoomreset  { my ZoomReset }
            help       { my CmdHelp }
            about      { my CmdAbout }
        }
    }

    method CmdNew {} {
        catch {$S destroy}
        set S [::schem::new untitled]
        set Placed [dict create] ; set Wires {} ; set Sel "" ; set Counter [dict create]
        set File "" ; set Dirty 0 ; set Result none
        my Redraw ; my ShowInspector ; my SetStatus "New board."
    }

    method CmdDelete {} {
        if {$Sel eq ""} { my SetStatus "Nothing selected." ; return }
        # remove wires touching it
        set kept {}
        foreach w $Wires {
            lassign $w a b
            if {[lindex [split $a .] 0] eq $Sel || [lindex [split $b .] 0] eq $Sel} continue
            lappend kept $w
        }
        set Wires $kept
        catch {$S remove $Sel}
        set Placed [dict remove $Placed $Sel]
        my SetStatus "Deleted $Sel"
        set Sel "" ; set Dirty 1 ; set Result none
        my Redraw ; my ShowInspector
    }

    method CmdRotate {} {
        if {$Sel eq ""} { my SetStatus "Select a part to rotate." ; return }
        set r [expr {([dict get $Placed $Sel rot] + 90) % 360}]
        dict set Placed $Sel rot $r
        set Dirty 1
        my Redraw
        my SetStatus "$Sel rotated to ${r} deg"
    }

    method CmdClear {} {
        set Placed [dict create] ; set Wires {} ; set Sel ""
        catch {$S destroy} ; set S [::schem::new untitled]
        set Result none ; set Dirty 1
        my Redraw ; my ShowInspector ; my SetStatus "Board cleared."
    }

    method CmdSolve {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to solve." ; return }
        if {[catch {$S solve} err]} { my SetStatus "solve error: $err" ; return }
        set Result solved
        set f [$S faults]
        my Redraw ; my ShowInspector
        if {[llength $f]} {
            my SetStatus "Solved with [llength $f] fault(s): [dict get [lindex $f 0] detail]"
        } else {
            my SetStatus "Solved.  Probe nodes, or run a Design review." "OK"
        }
    }

    method CmdValidate {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to validate." ; return }
        my SyncPositions
        set rep [$S validateText]
        set findings [$S validate]
        my TextDialog "Design-rule check" $rep
        if {[llength $findings]} {
            my SetStatus "[llength $findings] design-rule finding(s)." "WARN"
        } else {
            my SetStatus "Design-rule check passed." "OK"
        }
    }

    method CmdNetlist {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to net." ; return }
        my SyncPositions
        my TextDialog "Netlist (derived)" [$S netlistText] .txt
        my SetStatus "Netlist shown."
    }

    method CmdCompile {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to compile." ; return }
        my SyncPositions
        if {[catch {::schem::emit $S zig} src]} { my SetStatus "compile error: $src" ; return }
        set n [llength [split $src \n]]
        my TextDialog "Compiled to Zig  ·  $n lines  ·  build with: zig run FILE.zig" $src .zig
        my SetStatus "Compiled to Zig ($n lines).  Save and `zig run` it." "OK"
    }

    method CmdTransient {} {
        if {[dict size $Placed] == 0} { my SetStatus "Nothing to run." ; return }
        my SyncPositions
        my TransientDialog
    }

    method CmdFitAll {} { my FitToContent ; my Redraw }

    method CmdReview {} {
        my CmdSolve
        set findings [::schem::ratings::check $S]
        # attach per-part findings + verdict
        set worst [dict create]
        foreach r $findings {
            set p [dict get $r part]
            dict lappend Placed_ratings $p $r
        }
        # reset verdicts
        dict for {name pl} $Placed {
            set rs [expr {[info exists Placed_ratings] && [dict exists $Placed_ratings $name] ? [dict get $Placed_ratings $name] : {}}]
            dict set Placed $name ratings $rs
            set v ok
            foreach r $rs {
                if {[dict get $r verdict] eq "over"} { set v over ; break }
                if {[dict get $r verdict] eq "marginal"} { set v marginal }
            }
            if {[llength $rs]} { dict set Placed $name verdict $v } else { dict unset Placed $name verdict }
        }
        set nover 0 ; set nmarg 0
        foreach r $findings {
            if {[dict get $r verdict] eq "over"} { incr nover }
            if {[dict get $r verdict] eq "marginal"} { incr nmarg }
        }
        my Redraw ; my ShowInspector
        if {$nover} {
            my SetStatus "Design review: $nover OVER LIMIT, $nmarg marginal -- see red parts." "FAIL"
        } elseif {$nmarg} {
            my SetStatus "Design review: $nmarg marginal (>80% of rating) -- amber parts." "WARN"
        } elseif {[llength $findings]} {
            my SetStatus "Design review: all real parts within ratings." "OK"
        } else {
            my SetStatus "No real parts placed -- nothing to review (place parts, not just primitives)."
        }
    }

    method CmdSave {} {
        if {$File eq ""} { my CmdSaveAs ; return }
        my SyncPositions
        if {[catch {::schem::save $S $File} err]} { my SetStatus "save error: $err" ; return }
        set Dirty 0
        my SetStatus "Saved $File"
    }

    method CmdSaveAs {} {
        set f [tk_getSaveFile -defaultextension .schem -filetypes {{Schematic {.schem}}}]
        if {$f eq ""} return
        set File $f ; my CmdSave
    }

    method CmdOpen {} {
        set f [tk_getOpenFile -filetypes {{Schematic {.schem}} {All *}}]
        if {$f eq ""} return
        if {[catch {::schem::load $f} ns]} { my SetStatus "open error: $ns" ; return }
        catch {$S destroy} ; set S $ns ; set File $f ; set Dirty 0 ; set Result none
        my RebuildFromSchematic
        my SetStatus "Opened $f"
    }

    method SyncPositions {} {
        dict for {name pl} $Placed {
            catch {$S place $name [expr {[dict get $pl x]/$Grid}] [expr {[dict get $pl y]/$Grid}]}
        }
    }

    method RebuildFromSchematic {} {
        set Placed [dict create] ; set Wires {}
        foreach name [$S components] {
            set a [$S attrs $name]
            set pos [dict get $a pos]
            if {$pos eq ""} { set x 200 ; set y 200 } else {
                set x [expr {int([lindex $pos 0])*$Grid + 100}]
                set y [expr {int([lindex $pos 1])*$Grid + 100}]
            }
            dict set Placed $name [dict create type [$S typeof $name] x $x y $y rot 0 \
                partid [::schem::parts::idOf $S $name] pinabs {}]
        }
        foreach co [$S conns] {
            lassign $co a b
            lappend Wires [list $a $b]
        }
        set Sel ""
        my Redraw ; my ShowInspector
    }

    method CmdExportSvg {} {
        set f [tk_getSaveFile -defaultextension .svg -filetypes {{SVG {.svg}}}]
        if {$f eq ""} return
        my SyncPositions
        if {[catch {::schem::svgFile $S $f -title [$S name]} err]} { my SetStatus "export error: $err" ; return }
        my SetStatus "Exported image to $f"
    }

    method CmdExportPcb {} {
        set f [tk_getSaveFile -filetypes {{All *}}]
        if {$f eq ""} return
        set base [file rootname $f]
        if {[catch {::schem::pcb::export $S $base} res]} { my SetStatus "PCB export error: $res" ; return }
        set w [llength [dict get $res warnings]]
        my SetStatus "Exported [dict get $res netlist] + [dict get $res bom]  ($w manufacturability note(s))"
    }

    method CmdQuit {} {
        if {$Dirty} {
            set a [tk_messageBox -type yesnocancel -message "Save changes before quitting?" -icon question]
            if {$a eq "cancel"} return
            if {$a eq "yes"} { my CmdSave }
        }
        destroy $Win
        exit
    }

    method CmdHelp {} {
        my TextDialog "Keys & tools" \
"TOOLS
  Select   click to select; drag to move; double-click a switch/button/breaker
           to operate it; edit values in the Inspector
  Wire     click a pin, then click another pin
  Probe    after Solve, click a pin for node voltage, or a part for I and P

NAVIGATION
  +  -      zoom in / out          0   zoom to 100%        F   fit board to window
  Ctrl+wheel  zoom toward cursor   middle-drag  pan        wheel  scroll

KEYS
  F5  Solve      R  Rotate      Del  Delete      T  ANSI / IEC symbols
  Ctrl+N / O / S   New / Open / Save

ANALYSIS
  Solve            DC operating point; Inspector shows V, I, P for the part
  Transient…       time-domain run with a live oscilloscope plot (AC, RC/RL)
  AC sweep…        frequency response as a Bode plot (magnitude dB + phase)
  Design-rule check   anti-spaghetti + electrical checks
  Design review    every real part vs its datasheet ratings (over = red)

OUTPUT
  Export image (SVG)        a drawing of the schematic
  Export PCB (KiCad + BOM)  the files a board house manufactures from
  Compile to Zig            the board as a standalone Zig program (zig run)
  Show netlist              the derived nodes + elements

WORKFLOW
  1. Click or drag a part from the bin onto the board
  2. Wire the pins (Wire tool)
  3. Solve (F5); Probe nodes; or run a Transient
  4. Design review checks real parts against datasheet ratings
  5. Export PCB, or Compile to Zig"
    }

    method CmdAbout {} {
        tk_messageBox -type ok -title "About Schem" -message \
"Schem -- a visual electrical programming language.\n\nThe schematic IS the program.  Build circuits from real parts with\ndatasheet specs and limits, simulate them, review them against ratings,\nand export to KiCad + BOM for manufacture."
    }

}
