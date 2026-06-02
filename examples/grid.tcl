# grid.tcl --
#
# The top of the hierarchy: Component -> Circuit -> Panel -> Grid.
#
# A grid is a bounded collection of panels; a panel a collection of circuits;
# a circuit a collection of components.  Here a grid holds two independent
# counter panels (a real plant might hold many subsystems), each a counter
# circuit, each a tree of flip-flops, each a tree of relays.  They are wired
# and solved as one flat electrical network, yet authored and addressed by
# their place in the hierarchy: GRID / PANEL / CIRCUIT / component.
#
#   run with:  tclsh examples/grid.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here .. src schem.tcl]
source [file join $here .. lib logic logic.tcl]
source [file join $here .. lib logic catalog.tcl]

# a panel = a counter circuit with its ports lifted to the panel boundary
proc counter_panel {name} {
    set pan [schem::panel $name]
    set c [$pan instantiate [schem::lib::counter CT 2] C]
    foreach p {VCC GND CLK Q0 Q1} { $pan expose $p [dict get $c $p] }
    return $pan
}

# the grid: a shared supply and two counter panels on their own clocks
set grid [schem::grid plant]
$grid add battery VCC -emf 12 ; $grid add ground GND ; $grid wire VCC.neg GND.t
set A [$grid instantiate [counter_panel A] A]
set B [$grid instantiate [counter_panel B] B]
foreach m [list $A $B] { $grid wire [dict get $m VCC] VCC.pos ; $grid wire [dict get $m GND] GND.t }
$grid add switch CKA ; $grid wire VCC.pos CKA.a ; $grid wire CKA.b [dict get $A CLK]
$grid add switch CKB ; $grid wire VCC.pos CKB.a ; $grid wire CKB.b [dict get $B CLK]

proc rd {grid m} { set v 0 ; foreach b {0 1} { if {[$grid probe [dict get $m Q$b]] > 6} { set v [expr {$v|(1<<$b)}] } } ; return $v }
proc tick {grid sw} { $grid open $sw ; $grid solve ; $grid close $sw ; $grid solve }

set relays 0 ; foreach c [$grid components] { if {[$grid typeof $c] eq "relay"} { incr relays } }
puts "Grid \"plant\": [llength [$grid components]] components, $relays relays, across 2 panels\n"
$grid open CKA ; $grid open CKB ; $grid solve
puts "  panel A counts on clock A; panel B is independent:"
puts [format "    start    A=%d  B=%d" [rd $grid $A] [rd $grid $B]]
tick $grid CKA ; tick $grid CKA ; puts [format "    A++ A++  A=%d  B=%d" [rd $grid $A] [rd $grid $B]]
tick $grid CKB ;                  puts [format "    B++      A=%d  B=%d" [rd $grid $A] [rd $grid $B]]
tick $grid CKA ;                  puts [format "    A++      A=%d  B=%d" [rd $grid $A] [rd $grid $B]]

# the full 4-level path addresses a single relay deep inside panel A's counter
set deep [lindex [lsort [$grid components]] 0]
puts "\n  one component, addressed through the whole hierarchy:"
puts "    e.g. \"$deep\"  (grid / panel / circuit / ... / component)"
$grid destroy
puts ""
