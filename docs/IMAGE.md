# Rendering a schematic to an image

`bin/schem image` draws a `.schem` as an SVG — the same box-and-arrow view
the ASCII viewer gives (`schem open`), in the dark "Code panel" style, but
scalable and shareable. The image is a *view* of the object model; the
`.schem` schematic remains the source.

```sh
schem image FILE.schem OUT.svg            # flat: one box per component
schem image FILE.schem OUT.svg -grouped   # collapse NAME#i bundles to ribbons
```

A component is a rounded box labelled `NAME:type` (the name bright, the
`:type` dimmed); a wire is an arrowed line from source box to destination.
Layout reuses the engine's `FlowLayout`, so the picture matches the
canonical drawing: explicit `-at x,y` positions when present, otherwise
signal-flow columns with parts stacked into rows.

## Flat vs grouped

The **flat** view draws every component. It is perfect for small boards (a
divider, a relay gate, the switch→relay→breaker example) and faithfully
shows each part — but a bus machine with hundreds of lanes becomes a very
tall strip.

The **grouped** view collapses each bundle (`NAME#0..NAME#k`, the parts a
`bus` or `bank` creates) into a single ribbon box labelled `NAME[width]`,
and draws one ribbon connector between two bundles when any of their lanes
are wired together. This is how an engineer draws a bus — a ribbon, not 26
conductors — and it makes the big machines legible:

- the Enigma scrambler reads as `IN[26] → scrambler → OUT[26] → lampboard`;
- the bombe reads as ~18 letter-cables (`CAB_A[26]` …) meshed by the
  scramblers and Welchman's diagonal board, with the lamp panel, pulldowns
  and seed drive along the bottom.

Grouping is inferred from the `#` naming convention, so it works on any
loaded `.schem` without the format having to store bundle metadata.

## Rasterizing

The output is SVG (vector). To get a PNG, use any SVG rasterizer, e.g.:

```sh
python3 -c "import cairosvg; cairosvg.svg2png(url='out.svg', write_to='out.png', scale=2)"
```

Committed examples live under `artifacts/img/`.
