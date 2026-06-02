# editor.tcl --
#
# The interactive workbench.  The editor authors the schematic *object
# model* directly -- placing components on a grid, wiring their terminals,
# setting parameters -- and reads/writes the binary .schem project file.
# It never edits text: the artifact it manipulates is the schematic.
#
# The logic lives in EditorSession, a headless, fully testable core: it
# owns a schematic, a cursor and a mode, processes named key events, and
# renders a complete text frame.  The terminal front end (bin/schem-edit,
# invoked by `schem edit`) is a thin loop that turns keystrokes into
# EditorSession key events and prints the frames -- so the workbench can be
# driven and verified without a real TTY.

oo::class create ::schem::EditorSession {
    variable S File Cur Cells Bin BinIdx Mode Status Dirty Quit
    variable WireFrom PinComp PinList PinIdx PinStage
    variable InBuf InLabel InAction InComp Report Counters
    variable Zoom ZoomAnchor     ;# semantic zoom: level 0..maxLevel + focus key

    # placeable part palette and auto-name prefixes
    variable Palette
    variable Prefix

    constructor {{schem {}}} {
        set Palette {battery ground resistor capacitor inductor switch \
                     button relay breaker fuse diode bus junction ammeter}
        set Prefix {battery B ground GND resistor R capacitor C inductor L \
                    switch SW button BTN relay K breaker CB fuse F diode D \
                    bus BUS junction J ammeter A}
        if {$schem eq {}} { set S [::schem::new untitled] } else { set S $schem }
        set File ""
        set Cur {0 0}
        set Bin $Palette ; set BinIdx 0
        set Mode place ; set Status "ready" ; set Dirty 0 ; set Quit 0
        set WireFrom "" ; set PinComp "" ; set PinList {} ; set PinIdx 0 ; set PinStage from
        set InBuf "" ; set InLabel "" ; set InAction "" ; set InComp ""
        set Report "" ; set Counters [dict create]
        my Recell
        set Zoom [::schem::zoom::maxLevel $S]   ;# start fully zoomed in
        set ZoomAnchor ""
    }

    destructor { catch {$S destroy} }

    method schematic {} { return $S }
    method setFile {f} { set File $f }
    method quit? {} { return $Quit }
    method mode {} { return $Mode }
    method status {} { return $Status }
    method cursor {} { return $Cur }
    method zoom {} { return $Zoom }
    method zoomMax {} { return [::schem::zoom::maxLevel $S] }
    method zoomAnchor {} { return $ZoomAnchor }

    # setZoom -- set the level of detail, clamped to the board's own depth (the
    # language limits): 0 is the coarsest whole-board view, maxLevel the finest
    # per-component view where editing happens.  Resets the anchor.
    method setZoom {level} {
        set Zoom [::schem::zoom::clamp $S $level]
        set ZoomAnchor ""
        set Cur {0 0}
        my ZoomStatus
    }

    method ZoomStatus {} {
        set max [::schem::zoom::maxLevel $S]
        set nm [::schem::zoom::levelName $Zoom $max]
        set anc [expr {$ZoomAnchor ne "" ? "  @ [::schem::zoom::leaf $ZoomAnchor]" : ""}]
        set Status "zoom $Zoom/$max ($nm)$anc"
    }

    # zoomAt -- anchored zoom: change level by `delta` while keeping the part
    # the cursor is over in view.  Zooming IN descends into the group under the
    # cursor (the anchor becomes that group's key); zooming OUT rises to the
    # parent group.  This is the scroll-wheel-toward-the-pointer behaviour: the
    # thing you point at is what you dive into or pull back from.
    method zoomAt {delta} {
        set max [::schem::zoom::maxLevel $S]
        set target [::schem::zoom::clamp $S [expr {$Zoom + $delta}]]
        if {$target == $Zoom} { my ZoomStatus ; return }

        if {$delta > 0} {
            # zoom in: anchor on the group currently under the cursor, so the
            # finer view shows that group's children.
            set focus [my GroupAtCursor]
            if {$focus ne ""} { set ZoomAnchor $focus }
        } else {
            # zoom out: rise to the anchor's parent so the cursor's part stays
            # framed by its enclosing block.
            if {$ZoomAnchor ne ""} {
                set ZoomAnchor [::schem::zoom::parentKey $ZoomAnchor]
                if {[::schem::zoom::parentKey $ZoomAnchor] eq $ZoomAnchor && $target == 0} {
                    set ZoomAnchor ""
                }
            }
        }
        set Zoom $target
        my ZoomCursorToAnchor
        my ZoomStatus
    }

    # GroupAtCursor -- the collapsed-group key the cursor currently points at in
    # the zoom overview (or the component under the cursor at the finest level).
    method GroupAtCursor {} {
        if {$Zoom >= [::schem::zoom::maxLevel $S]} {
            return [my CompAt {*}$Cur]
        }
        lassign [::schem::zoom::groups $S $Zoom] order members gtype
        lassign $Cur cc cr
        return [lindex $order $cr]
    }

    # ZoomCursorToAnchor -- after a level change, place the cursor on the row of
    # the group that contains the anchor, so the focus stays put.
    method ZoomCursorToAnchor {} {
        if {$ZoomAnchor eq ""} { set Cur {0 0} ; return }
        if {$Zoom >= [::schem::zoom::maxLevel $S]} {
            # finest: land on a member component of the anchored group
            lassign [::schem::zoom::groups $S [expr {$Zoom-1}]] order members gtype
            if {[dict exists $members $ZoomAnchor]} {
                set first [lindex [dict get $members $ZoomAnchor] 0]
                set rc [dict get $Cells $first]
                if {$rc ne ""} { set Cur $rc ; return }
            }
            set Cur {0 0} ; return
        }
        lassign [::schem::zoom::groups $S $Zoom] order members gtype
        set i 0
        foreach k $order {
            # the anchor is this row if it equals the row key or descends from it
            if {$k eq $ZoomAnchor || [string match "$k/*" $ZoomAnchor] || [string match "$ZoomAnchor*" $k]} {
                set Cur [list 0 $i] ; return
            }
            incr i
        }
        set Cur {0 0}
    }

    # Recell -- (re)derive the integer cell grid from the model and commit
    # those positions back, so the model's positions are the editor grid.
    method Recell {} {
        set Cells [$S FlowLayout]
        dict for {c rc} $Cells { lassign $rc col row ; $S place $c $col $row }
    }

    method CompAt {col row} {
        dict for {c rc} $Cells { if {$rc eq [list $col $row]} { return $c } }
        return ""
    }

    method Bounds {} {
        set mc 0 ; set mr 0
        dict for {c rc} $Cells {
            lassign $rc col row
            if {$col > $mc} { set mc $col } ; if {$row > $mr} { set mr $row }
        }
        return [list [expr {$mc+1}] [expr {$mr+1}]]
    }

    method AutoName {type} {
        set pfx [expr {[dict exists $Prefix $type] ? [dict get $Prefix $type] : [string toupper [string index $type 0]]}]
        set n [expr {[dict exists $Counters $pfx] ? [dict get $Counters $pfx] : 0}]
        while {1} {
            incr n
            set name "$pfx$n"
            if {$name ni [$S components]} break
        }
        dict set Counters $pfx $n
        return $name
    }

    # ---- key handling ----------------------------------------------
    # key -- process one event.  k is a printable char or one of:
    #   UP DOWN LEFT RIGHT ENTER ESC BACKSPACE SPACE
    method key {k} {
        switch -- $Mode {
            place  { my KeyPlace  $k }
            pin    { my KeyPin    $k }
            prompt { my KeyPrompt $k }
            report { set Mode place ; set Status "ready" }
            default { set Mode place }
        }
        return
    }

    # feed a string of plain character keys (test convenience)
    method type {s} { foreach c [split $s ""] { my key $c } }

    method KeyPlace {k} {
        lassign [my Bounds] maxc maxr
        lassign $Cur cc cr
        switch -- $k {
            h - LEFT  { if {$cc>0}     { set Cur [list [expr {$cc-1}] $cr] } }
            l - RIGHT { if {$cc<$maxc} { set Cur [list [expr {$cc+1}] $cr] } }
            k - UP    { if {$cr>0}     { set Cur [list $cc [expr {$cr-1}]] } }
            j - DOWN  { if {$cr<$maxr} { set Cur [list $cc [expr {$cr+1}]] } }
            "\[" - ","  { set BinIdx [expr {($BinIdx-1+[llength $Bin])%[llength $Bin]}] ; set Status "part: [lindex $Bin $BinIdx]" }
            "\]" - "."  { set BinIdx [expr {($BinIdx+1)%[llength $Bin]}] ; set Status "part: [lindex $Bin $BinIdx]" }
            p - " " - SPACE { my DoPlace }
            d         { my DoDelete }
            w         { my DoWire }
            e         { my DoEditParam }
            s         { my DoSolve }
            v         { set Report [$S validateText] ; set Mode report }
            S         { my DoSaveStart }
            o         { my DoOpenStart }
            "?"       { set Report [my HelpText] ; set Mode report }
            "+" - "=" { my zoomAt 1 }
            "-" - "_" { my zoomAt -1 }
            ESC       { if {$WireFrom ne ""} { set WireFrom "" ; set Status "wire cancelled" } }
            q         { set Quit 1 }
            default {
                if {[string is digit -strict $k] && $k ne "0"} {
                    set i [expr {$k-1}]
                    if {$i < [llength $Bin]} { set BinIdx $i ; set Status "part: [lindex $Bin $BinIdx]" }
                }
            }
        }
    }

    method DoPlace {} {
        lassign $Cur col row
        if {[my CompAt $col $row] ne ""} { set Status "cell occupied" ; return }
        set type [lindex $Bin $BinIdx]
        set name [my AutoName $type]
        $S add $type $name -at $col,$row
        dict set Cells $name [list $col $row]
        set Dirty 1 ; set Status "placed $name ($type)"
    }

    method DoDelete {} {
        lassign $Cur col row
        set c [my CompAt $col $row]
        if {$c eq ""} { set Status "nothing here" ; return }
        $S remove $c
        dict unset Cells $c
        if {$WireFrom ne "" && [lindex [split $WireFrom .] 0] eq $c} { set WireFrom "" }
        set Dirty 1 ; set Status "deleted $c"
    }

    method DoWire {} {
        lassign $Cur col row
        set c [my CompAt $col $row]
        if {$c eq ""} { set Status "no component to wire here" ; return }
        set PinComp $c
        set PinList [$S terminals $c]
        set PinIdx 0
        set PinStage [expr {$WireFrom eq "" ? "from" : "to"}]
        set Mode pin
        set Status "select [expr {$PinStage eq {from} ? {source} : {destination}}] terminal of $c"
    }

    method KeyPin {k} {
        switch -- $k {
            k - UP - "\[" - "," { set PinIdx [expr {($PinIdx-1+[llength $PinList])%[llength $PinList]}] }
            j - DOWN - "\]" - "." { set PinIdx [expr {($PinIdx+1)%[llength $PinList]}] }
            ENTER - " " - SPACE {
                set pin [lindex $PinList $PinIdx]
                set term "$PinComp.$pin"
                if {$PinStage eq "from"} {
                    set WireFrom $term ; set Mode place
                    set Status "wiring from $term -- move to target, press w"
                } else {
                    if {[catch {$S wire $WireFrom $term} err]} {
                        set Status "wire failed: $err"
                    } else {
                        set Status "wired $WireFrom -> $term" ; set Dirty 1
                    }
                    set WireFrom "" ; set Mode place
                }
            }
            ESC { set Mode place ; set Status "cancelled" ; if {$PinStage eq "from"} { set WireFrom "" } }
        }
    }

    method DoEditParam {} {
        lassign $Cur col row
        set c [my CompAt $col $row]
        if {$c eq ""} { set Status "no component here" ; return }
        set InComp $c ; set InAction param ; set InBuf ""
        set InLabel "set param for $c (e.g. r 2200 | emf 12 | state closed):"
        set Mode prompt
    }

    method DoSolve {} {
        if {[catch {$S solve} _ opts]} {
            if {[lrange [dict get $opts -errorcode] 0 1] eq {SCHEM SINGULAR}} {
                set Status "SOLVE: short circuit"
            } else { set Status "SOLVE error" }
            return
        }
        set nf [llength [$S faults]]
        set Status "solved: [llength [$S components]] parts, $nf fault(s)[expr {$nf?{ -- press v}:{}}]"
    }

    method DoSaveStart {} {
        if {$File ne ""} {
            schem::save $S $File ; set Dirty 0 ; set Status "saved $File"
        } else {
            set InAction save ; set InBuf "" ; set InLabel "save as (path):" ; set Mode prompt
        }
    }
    method DoOpenStart {} {
        set InAction open ; set InBuf "" ; set InLabel "open (path):" ; set Mode prompt
    }

    method KeyPrompt {k} {
        switch -- $k {
            ENTER     { my CommitPrompt }
            ESC       { set Mode place ; set Status "cancelled" }
            BACKSPACE { set InBuf [string range $InBuf 0 end-1] }
            default   { if {[string length $k] == 1} { append InBuf $k } }
        }
    }

    method CommitPrompt {} {
        set Mode place
        switch -- $InAction {
            param {
                set parts $InBuf
                if {[llength $parts] != 2} { set Status "expected: key value" ; return }
                lassign $parts key val
                if {[catch {$S set $InComp $key $val} err]} { set Status "set failed: $err" } \
                else { set Dirty 1 ; set Status "$InComp $key = $val" }
            }
            save {
                if {$InBuf eq ""} { set Status "save cancelled" ; return }
                set File $InBuf
                if {[catch {schem::save $S $File} err]} { set Status "save failed: $err" } \
                else { set Dirty 0 ; set Status "saved $File" }
            }
            open {
                if {$InBuf eq ""} { set Status "open cancelled" ; return }
                if {[catch {schem::load $InBuf} new]} { set Status "open failed: $new" ; return }
                catch {$S destroy}
                set S $new ; set File $InBuf ; set Cur {0 0} ; set WireFrom ""
                my Recell ; set Dirty 0 ; set Status "opened $InBuf"
            }
        }
    }

    method HelpText {} {
        return "Schem Editor -- keys
  arrows / hjkl   move cursor
  \[  \]            previous / next part in the bin   (or 1-9)
  p or space      place selected part at the cursor
  d               delete the component at the cursor
  w               wire: pick a source terminal, move, press w again for dest
  e               edit a parameter of the component at the cursor
  s               solve (run the interpreter)
  v               validate (anti-spaghetti + electrical checks)
  S               save .schem      o  open .schem
  ?               this help        q  quit
press any key to close"
    }

    # ---- rendering -------------------------------------------------
    # ZoomOverview -- the collapsed view at the current (coarse) zoom level: a
    # box per group (an instance, a circuit, a bus -- whatever the level keeps),
    # labelled NAME[n]:type, with a degree count of how many other groups it
    # wires to.  The cursor (row) selects a group; '+' drills into it.  This is
    # the wide, coarse control -- a minimap over the same board the component
    # level edits in full.
    method ZoomOverview {} {
        lassign [::schem::zoom::groups $S $Zoom] order members gtype
        # degree: distinct neighbour groups
        set deg [dict create]
        foreach pr [::schem::zoom::edges $S $Zoom] {
            lassign $pr a b
            dict incr deg $a ; dict incr deg $b
        }
        lassign $Cur cc cr
        if {$cr >= [llength $order]} { set cr [expr {[llength $order]-1}] }
        if {$cr < 0} { set cr 0 }
        set Cur [list 0 $cr]
        set max [::schem::zoom::maxLevel $S]
        set out {}
        lappend out "level $Zoom/$max ([::schem::zoom::levelName $Zoom $max])   ([llength $order] groups, [llength [$S components]] components)"
        set i 0
        foreach k $order {
            set n [llength [dict get $members $k]]
            set base [::schem::zoom::leaf $k]
            set lbl [expr {$n > 1 ? "$base\[$n\]" : $base}]
            set d [expr {[dict exists $deg $k] ? [dict get $deg $k] : 0}]
            set onanchor [expr {$ZoomAnchor ne "" && ($k eq $ZoomAnchor || [string match "$k/*" $ZoomAnchor])}]
            set mark [expr {$i == $cr ? [format %c 0x25B6] : ($onanchor ? "*" : " ")}]
            lappend out [format "  %s %-24s links:%d" $mark $lbl:[dict get $gtype $k] $d]
            incr i
        }
        return $out
    }

    method render {} {
        set out {}
        set star [expr {$Dirty ? "*" : ""}]
        set fname [expr {$File eq "" ? "(unsaved)" : $File}]
        lappend out "[format %c 0x2301] Schem Editor -- $fname$star"
        lappend out [string repeat [format %c 0x2500] 60]

        if {$Mode eq "report"} {
            foreach ln [split $Report \n] { lappend out $ln }
            return [join $out \n]
        }

        # canvas: at the finest zoom (component) draw the full editable board;
        # at coarser zooms draw the collapsed semantic-zoom overview.
        if {$Zoom >= [::schem::zoom::maxLevel $S]} {
            set canvas [::schem::DrawCanvas $S $Cells \
                [list cursor $Cur showEmpty 1 extraCols 1 extraRows 1]]
        } else {
            set canvas [my ZoomOverview]
        }
        foreach ln $canvas { lappend out $ln }
        lappend out [string repeat [format %c 0x2500] 60]

        # part bin
        set bin "BIN:"
        for {set i 0} {$i < [llength $Bin]} {incr i} {
            set t [lindex $Bin $i]
            if {$i == $BinIdx} { append bin " \[$t\]" } else { append bin " $t" }
        }
        lappend out $bin

        if {$Mode eq "pin"} {
            set pins "PINS of $PinComp:"
            for {set i 0} {$i < [llength $PinList]} {incr i} {
                set p [lindex $PinList $i]
                if {$i == $PinIdx} { append pins " \[$p\]" } else { append pins " $p" }
            }
            lappend out $pins
            lappend out "(j/k choose, ENTER select, ESC cancel)"
        } elseif {$Mode eq "prompt"} {
            lappend out "$InLabel"
            lappend out "> $InBuf[format %c 0x2588]"
        } else {
            set wf [expr {$WireFrom ne "" ? "  wiring-from: $WireFrom" : ""}]
            lappend out "cursor: [lindex $Cur 0],[lindex $Cur 1]   mode: $Mode$wf"
        }
        lappend out "status: $Status"
        lappend out "keys: move=hjkl/arrows  place=p  wire=w  param=e  solve=s  validate=v  zoom=+/-  save=S  open=o  help=?  quit=q"
        return [join $out \n]
    }
}
