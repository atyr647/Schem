# Committed `.schem` artifacts

These are real Schem programs — binary `.schem` schematics, the project's
actual source format. They are not Tcl. Open them with the viewer to read
them as the box-and-arrow diagrams they are:

```sh
bin/schem open artifacts/enigma_scrambler.schem    # draw it
bin/schem netlist artifacts/enigma_scrambler.schem # derived connectivity
```

A `.schem` is a serialized schematic object model (components, terminals,
wires, positions) — see `docs/FORMAT.md`. The *content* is the schematic;
the bytes on disk are just a zlib container. The renderer draws boxes for
components and arrowed lines for the wires between them.

| file | what it is |
|------|-----------|
| `enigma_scrambler.schem` | an Enigma scrambler (a 26-lane involution) feeding a 26-lamp alphabet board — press key A, lamp U lights. 107 components. |
| `bombe_QER.schem` | the Turing bombe wired for the `WETTERVORHERSAGE` crib at the recovered ground `QER`: 18 letter-cables, the scramblers, Welchman's diagonal board, and a 26-lamp stop panel. Solve it and exactly one lamp (E) lights — the stop. 523 components. |

Regenerate them from their builders:

```sh
bin/schem save examples/enigma_scrambler.schem.tcl artifacts/enigma_scrambler.schem
```
