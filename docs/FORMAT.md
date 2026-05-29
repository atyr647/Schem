# The `.schem` project file

A `.schem` file is the **source of a Schem program**: a serialized
schematic object model.  It is a compact binary container meant to be
opened only through Schem tooling — it is *not* a text/JSON/SVG/ASCII
format, and it is not something you program in by hand.  This page
documents the container for implementers; it does not make the bytes "the
language."  (The language is the schematic.)

## Container

```
offset 0  magic            "SCHM"           4 bytes
       4  container version u8               (1)
       5  flags             u8               bit0 = zlib-compressed payload
       6  payload length    u32 big-endian   (uncompressed size)
      10  payload           zlib stream of the record body below
```

Strings are `u32` length + UTF-8 bytes.  Maps are `u32` count + key/value
string pairs.  All integers are big-endian.

```
u8  model version major, u8 model version minor
str schematic name
u32 component count
      str name, str type, map params, str pos ("x y" or ""), str layer
u32 coupling count
      str a, str b, str awg (""=ideal), str harness ("" if none)
u32 harness count
      str name, str layer, u32 members { str a, str b }
u32 port count
      str port, str term
```

The model stores exactly the schematic primitives: components and their
terminals, wires (couplings) with direction and gauge, junctions and buses
(single-terminal components everything attaches to), harness bundles,
layers, positions/bounds, ratings and state, plus the exposed ports that
make a schematic a reusable circuit.

## Reading & writing

```tcl
schem::save $s path.schem     ;# serialize the object model (returns byte count)
set s [schem::load path.schem] ;# reconstruct a live schematic
```

`load` reconstructs the schematic through the same workbench API used to
build one by hand, so a loaded board is indistinguishable from one created
in code and re-saves identically.

## Opening it (the viewer)

```tcl
puts [$s view]                 ;# draw the schematic as a wired box diagram
```

The viewer *draws* the object model — boxes for components, lines for
couplings, arrowheads for direction, straight drops/channels for vertical
and feedback routing.  It honours explicit component positions when the
model carries them, otherwise it lays parts out by signal flow.  It never
prints the schematic as a list of entities: there is no raw text view.

## Deriving the netlist (a cache, not the source)

```tcl
set ir  [$s netlist]           ;# structured IR: nodes, elements, ports
puts [$s netlistText]          ;# readable dump of the derived IR
```

The netlist flattens the hierarchy and resolves continuity (ideal wires,
buses, junctions and harnesses merge terminals into shared nodes; all
grounds become node 0).  It is what the interpreter solves and what future
backends (C / WASM / HDL) would consume.  It is regenerated on demand from
the schematic and is never authoritative.
