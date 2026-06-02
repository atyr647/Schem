# GUI screenshots

Every screen of the Schem visual workbench (`schem gui`).  Captured from the
running Tk app.

| Screen | Image |
|--------|-------|
| Welcome / empty board | ![welcome](09_welcome.png) |
| Main window — a reviewed circuit (the over-limit 1N4148 shown red; the inspector shows Values, Measured V/I/P and Ratings) | ![main](01_main.png) |
| Parts bin filtered to a category (Rectifier) | ![parts](02_parts_filtered.png) |
| Transient analysis — live oscilloscope (an AC source traced over time) | ![transient](03_transient.png) |
| AC frequency sweep — Bode plot (RC low-pass: flat passband, −3 dB knee, −20 dB/decade rolloff, with phase) | ![ac](04_acsweep.png) |
| Compile to Zig — the board emitted as a standalone Zig program | ![compile](05_compile.png) |
| Netlist viewer — the derived nodes + elements | ![netlist](06_netlist.png) |
| Design-rule check | ![drc](07_validate.png) |
| Help — keys & tools | ![help](08_help.png) |

Regenerate with the capture scripts under a virtual display
(`xvfb-run`), or just run `schem gui` and use the app.
