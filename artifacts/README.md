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
| `enigma_scrambler.schem` | an Enigma scrambler (a 26-lane involution) feeding a 26-lamp alphabet board — press key A, lamp U lights. 107 components, hierarchy depth 2 (`SC/IN#0` = instance, bundle, lane). |
| `bombe_QER.schem` | the Turing bombe wired for the `WETTERVORHERSAGE` crib at the recovered ground `QER`. Organised into panels — `POWER/`, `MENU/` (18 letter-cables + scramblers + Welchman's diagonal board), `REG/`, `LAMPS/` — so it has real zoom depth: 5 boxes at the grid level, opening down to 523 components. Solve it and exactly one lamp (E) lights — the stop. |

## Zoom levels (see `docs/ZOOM.md`)

Because the boards carry panel/bundle hierarchy in their names, the renderer
draws them at any level of detail:

```sh
bin/schem image artifacts/bombe_QER.schem out.svg -level 0   # 5 panels
bin/schem image artifacts/bombe_QER.schem out.svg -grouped   # 18 cables (mesh)
bin/schem image artifacts/bombe_QER.schem out.svg            # all 523 parts
```

`img/` holds rendered PNGs: `bombe_grid.png` (the 5-box overview),
`bombe_cables.png` (the cable mesh), `enigma_scrambler.png`,
`switch_relay_breaker.png`.

Regenerate the `.schem` files from their builders:

```sh
bin/schem save examples/enigma_scrambler.schem.tcl artifacts/enigma_scrambler.schem
```
