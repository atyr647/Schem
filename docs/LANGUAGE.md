# Schem / ⌁ — Visual Electrical Programming Language

> This document is the language definition. It is a manifesto and a
> specification, not a collection of ideas. Everything in Schem is built
> from abstract electrical concepts; no software-domain abstraction leaks
> into the model.

## Core Premise

Schem is a visual programming language based entirely on abstract
electrical concepts.

- The source code is not text.
- The source code is not JSON.
- The source code is not a hidden graph.
- The source code is the schematic itself.

Users, LLMs, editors, renderers, and interpreters all operate on the same
artifact.

**A schematic is the program. The schematic is the source of truth.**

---

## Design Philosophy

Everything in Schem is built from electrical abstractions.

**Sources** — Battery, Ground
**Conductors** — Wire, Bus, Junction, Harness
**Control** — Button, Switch, Relay, Breaker, Fuse, Diode
**Passive** — Resistor, Capacitor, Inductor
**Indicators** — Lamp (glows above a current threshold), Nixie tube
(displays the digit of whichever cathode is pulled low)
**Memory** — Capacitor, Latch, RAM/tape chip, Magnetic core (a
non-volatile bit set and read by coincident current)
**Measurement** — Meter, Probe, Continuity Tester
**Structural** — Circuit, Panel, Grid

No traditional programming concepts exist. No functions, variables,
classes, loops, syntax trees, code blocks, packages, namespaces, or
modules.

Behavior emerges from electrical relationships.

---

## Fundamental Rule

```
Parts
  ↓
Terminals
  ↓
Wires
  ↓
Continuity
  ↓
Current
  ↓
Behavior
```

If continuity exists, current may flow.
If current flows, behavior occurs.
No continuity means no behavior.

---

## Scale Hierarchy

Schem scales using the same hierarchy found in real electrical systems.

```
Component
    ↓
Circuit
    ↓
Panel
    ↓
Grid
```

### Component

Smallest visible primitive. Examples: Relay, Switch, Capacitor, Resistor,
Breaker, Wire.

### Circuit

A bounded collection of components. A circuit performs a single purpose.
Circuits expose terminals. Circuits hide internal complexity.

```
┌────────────────────┐
│ Circuit            │
│                    │
│ IN  ○              │
│ OUT ○              │
│ GND ○              │
└────────────────────┘
```

### Panel

A bounded collection of circuits. Panels organize circuits. Panels
introduce no new computational behavior; they only provide structure.

```
Panel
├─ Circuit
├─ Circuit
├─ Circuit
└─ Circuit
```

### Grid

A bounded collection of panels. Grids represent complete assemblies.

```
Grid
├─ Panel
├─ Panel
├─ Panel
└─ Panel
```

The same language describes a single switch, a relay assembly, a circuit,
a panel, or an entire grid. No additional abstraction system is required.

---

## Editor Model

The language behaves like a virtual electrical workbench.

```
┌──────────────────────────────────────────────┐
│ PART BIN                  WORKBENCH          │
│                                              │
│ Sources                                      │
│  [Battery]  [Ground]                         │
│ Conductors                                   │
│  [Wire] [Bus] [Junction] [Harness]           │
│ Control                                      │
│  [Switch] [Button] [Relay]                   │
│  [Breaker] [Fuse] [Diode]                    │
│ Passive                                      │
│  [Resistor] [Capacitor] [Inductor]           │
│ Test Tools                                   │
│  [Meter] [Probe] [Continuity Tester]         │
└──────────────────────────────────────────────┘
```

Users drag components onto a board, connect terminals, and shape
continuity and current flow. No coding is performed.

---

## Wires

Wires are not decorative. Wire properties matter.

```
22 AWG  ─────   low-capacity signal
14 AWG  ═════   normal flow
4 AWG   █████   high-capacity bus
```

Wire capacity becomes part of the language. Overloaded wires become
faults.

---

## Component Grammar

Every component is represented as a box. The label defines the component
type. Couplings (lines) connect boxes; arrowheads define direction.

```
┌─────────┐      ┌─────────┐
│ switch  │─────▶│ relay   │
└─────────┘      └────┬────┘
                      │
                      ▼
                 ┌─────────┐
                 │ breaker │
                 └─────────┘
```

- Boxes are components.
- Lines are couplings.
- Arrowheads define direction.
- Labels define component type.
- Nested diagrams become circuits.

---

## Electrical Semantics

These are the *meanings* of the primitives — what each electrical quantity
denotes inside a Schem program. They are not merely visual parts.

| Concept         | Semantics                                                        |
|-----------------|------------------------------------------------------------------|
| **Current**     | Activity, work, signal propagation. Flows only in closed loops.  |
| **Continuity**  | The possibility of flow: a conductive path exists.               |
| **Voltage**     | Potential difference; the driving force, measured against ground.|
| **Resistance**  | Opposition, friction, delay, throttling. Drops voltage as `V=IR`.|
| **Capacitance** | Stored energy, retained state, buffering. Resists *voltage* change; charges as `V(t)=E(1−e^{−t/RC})`. A capacitor is the language's memory cell. |
| **Inductance**  | Inertia, momentum, delayed reaction. Resists *current* change; current ramps as `I(t)=I_max(1−e^{−tR/L})`. |
| **Breakers**    | Protection and limits. Open (trip) above a current rating; resettable. |
| **Fuses**       | Irreversible faults. Open permanently above a current rating.    |
| **Relays**      | Conditional routing. A coil's current closes/opens isolated contacts — conditional behavior with no `if`. Real relays have **hysteresis** (a higher pick-up than drop-out current, so a held contact resists chatter) and a **propagation delay** (contacts move only after the coil condition persists for the operate/release time, so brief glitches are ignored and feedback loops can race). |
| **Diodes**      | One-way flow. Conduct only when forward-biased past `Vf`.        |
| **Buses**       | Shared conductors: one node many parts attach to.                |
| **Harnesses**   | Bundled conductors routed together between assemblies.           |
| **Circuits**    | Functional assemblies (a single purpose, exposed terminals).     |
| **Panels**      | Organizational assemblies (structure, no new behavior).          |
| **Grids**       | Complete assemblies.                                             |

### Sources & Reference

- **Battery** supplies an EMF (a fixed voltage) between its `pos` and
  `neg` terminals. It is the only thing that *originates* current. A real
  source also has an **internal resistance** (`esr`): its terminal voltage
  sags under load as `emf − I·esr`, and that same resistance bounds the
  current a dead short can draw to `emf/esr`.
- **Ground** defines the `0 V` reference. Every potential is measured
  against it, and current must be able to return to a source through
  ground (or a return conductor) for a loop to be closed.

### State and Memory

State — the ability to remember — is what lifts Schem from combinational
to general computation:

- **Capacitors** store charge (analog state / timing).
- **Latches** (a relay holding itself energised through its own contact)
  store a bit.
- **Counters** accumulate discrete events from feedback and state.

---

## Relays — Conditional Behavior Without `if`

A relay has two electrically isolated sides.

**Control side** (the coil):

```
[Battery]──[Button]──(Relay Coil)──[Ground]
```

**Switched side** (the contacts):

```
[Battery]──[Relay NO]──[Load]──[Ground]
```

Pressing the button energizes the coil; the contact closes; current flows
to the load. No `if` statement exists — the conditional behavior *emerges*
from the electrical relationship between coil and contact.

Wiring two NO contacts in **series** yields a logical **AND**; wiring them
in **parallel** yields a logical **OR**. Feeding a coil through its own NC
contact yields an **oscillator**.

---

## Computational Power

Schem becomes computationally universal through:

- State (capacitors, latches, counters)
- Conditional routing (relays)
- Feedback loops
- Signal propagation
- Sources and sinks

Historically, relay computers achieved arbitrary computation using exactly
these ingredients: relays, switches, signal paths, and state. Therefore
Schem is **computationally universal in principle**.

---

## Complexity Management

The biggest challenge is information density. One screen of text expresses
enormous complexity; one screen of diagrams expresses less. Therefore
Schem must enforce hierarchy:

```
Components → Circuits → Panels → Grids
```

The goal: **10,000 components** appearing to the user as **20 circuits, 5
panels, 1 grid**.

### Anti-Spaghetti Rules

1. **Circuits** — large boards must become circuits.
2. **Panels** — large circuit collections must become panels.
3. **Grids** — large panel collections must become grids.
4. **Named Buses** — replace long wires (`BUS: primary`, `BUS: fault`).
5. **Terminal Contracts** — `IN`, `OUT`, `FAULT`, `GND`.
6. **Layers** — Power, Control, Signal, Fault, Ground.
7. **Harnesses** — `[Circuit] === Harness === [Circuit]`.
8. **Board Limits** — the editor warns when complexity becomes excessive.
9. **Standard Circuits** — Debounce, Oscillator, Counter, Timer, Relay
   Bank, Safety Interlock, Pulse Generator.
10. **Live Path Tracing** — selecting a terminal highlights only connected
    continuity paths; everything else fades.

---

## Runtime Model

The interpreter sees exactly the same schematic the user sees. It does not
execute text. It reads Components, Couplings, Terminals, Continuity, and
State.

```
Find Sources
      ↓
Trace Continuity
      ↓
Apply Component Behavior
      ↓
Propagate Current
      ↓
Update State
      ↓
Generate Effects
```

The interpreter may construct temporary internal structures (for Schem's
reference implementation, a Modified Nodal Analysis matrix). Those
structures are not the source. The schematic remains the source.

---

## Language Identity

- Schem is **not** a visual scripting language.
- Schem is **not** a node editor.
- Schem is **not** a graphical front-end for textual code.

Schem is a visual electrical computation medium where the schematic itself
is the source code. Everything is electrical. Everything scales through
**Component → Circuit → Panel → Grid**.
