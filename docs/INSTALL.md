# Installing & running Schem

Schem is pure Tcl/Tk — there is nothing to compile and no package to install.
You only need the Tcl/Tk runtime; the GUI additionally needs Tk (which ships
with most Tcl installs).  The optional "compile to Zig" backend needs a Zig
compiler.

| You want… | You need |
|-----------|----------|
| The CLI (`schem run/solve/pcb/emit …`) | **Tcl 8.6+** |
| The visual workbench (`schem gui`) | **Tcl 8.6+ with Tk** |
| Compile a board to a runnable program | **Zig 0.13.0** (optional) |
| Rasterise exported SVGs to PNG | any SVG tool (optional) |

Tcl 8.6+ is required because Schem uses TclOO (the built-in object system).

---

## Linux

### Debian / Ubuntu / Mint / Pop!_OS
```sh
sudo apt-get update
sudo apt-get install tcl tk        # tk pulls in everything the GUI needs
git clone https://github.com/atyr647/Schem.git
cd Schem
./bin/schem -v                     # verify the CLI
./bin/schem gui                    # launch the workbench
```

### Fedora / RHEL / CentOS
```sh
sudo dnf install tcl tk
```

### Arch / Manjaro
```sh
sudo pacman -S tcl tk
```

### Alpine
```sh
sudo apk add tcl tk
```

If `./bin/schem` isn't executable: `chmod +x bin/schem bin/schem-gui`.

---

## macOS

Tcl/Tk ships with macOS but it's old; install a current one with Homebrew:

```sh
brew install tcl-tk
git clone https://github.com/atyr647/Schem.git
cd Schem
./bin/schem -v
./bin/schem gui
```

If `tclsh`/`wish` aren't found after `brew install`, add Homebrew's Tcl to your
PATH (Apple Silicon shown; use `/usr/local` on Intel):

```sh
echo 'export PATH="/opt/homebrew/opt/tcl-tk/bin:$PATH"' >> ~/.zshrc
exec zsh
```

---

## Windows

### 1. Install Tcl/Tk
Easiest is **Magicsplat Tcl/Tk for Windows** (a one-click installer that
bundles Tcl 8.6+, Tk, and `tclsh`/`wish`): https://www.magicsplat.com/tcl-installer/
— or **ActiveTcl** from ActiveState.  After installing, `tclsh` and `wish`
are on your PATH.

### 2. Get Schem
With Git:
```powershell
git clone https://github.com/atyr647/Schem.git
cd Schem
```
…or download the ZIP from GitHub and extract it.

### 3. Run it
The `bin/schem` launcher is a Unix shell script, so on Windows call the
interpreter directly:

```powershell
# CLI: run a board
tclsh bin\schem run examples\voltage_divider.schem.tcl

# GUI: the visual workbench
wish bin\schem-gui
```

You can make a desktop shortcut whose target is
`wish C:\path\to\Schem\bin\schem-gui` to launch the workbench with a click.

> Tip: in PowerShell, if `tclsh`/`wish` aren't recognised, use the full path
> the installer reported, e.g. `& "C:\Tcl\bin\wish.exe" bin\schem-gui`.

---

## Optional: the "Compile to Zig" backend

`schem emit zig` (CLI) and **File → Compile to Zig** (GUI) turn a board into a
standalone Zig program that solves it.  To *build and run* that program you
need Zig **0.13.0**:

1. Download from https://ziglang.org/download/ (the 0.13.0 release).
2. Unpack and put `zig` on your PATH, or point Schem at it:
   ```sh
   export SCHEM_ZIG=/path/to/zig-linux-x86_64-0.13.0/zig
   ```
3. Build a compiled board:
   ```sh
   schem emit zig board.schem > board.zig
   zig run board.zig
   ```

The backend cross-check tests (`tests/test_cir.tcl`) use `SCHEM_ZIG` (or `zig`
on PATH) and skip cleanly when neither is present.

---

## Optional: rasterising exported images

`schem image board.schem out.svg` writes SVG (vector, opens in any browser).
To convert to PNG, any of these work:

```sh
# rsvg
rsvg-convert out.svg -o out.png
# Inkscape
inkscape out.svg --export-filename=out.png
# cairosvg (Python)
python3 -c "import cairosvg; cairosvg.svg2png(url='out.svg', write_to='out.png', scale=2)"
```

---

## Verifying your install

```sh
make test          # run the regression suite (needs tclsh; GUI tests need Tk)
```

or without `make`:

```sh
tclsh tests/test_schem.tcl     # engine
tclsh tests/test_parts.tcl     # real parts + ratings
DISPLAY=:0 wish tests/test_gui.tcl   # GUI (needs a display)
```

A green run means the engine reproduces Ohm's law, Kirchhoff's laws, the RC
time constant, and the AC corner frequency on your machine.

## Troubleshooting

- **`can't find package Tk`** — install the `tk` package (separate from `tcl`
  on some distros), then retry `schem gui`.
- **`couldn't connect to display`** — the GUI needs a graphical session; over
  SSH use `ssh -X`, or run headless under `xvfb-run wish bin/schem-gui`.
- **Garbled units (Ω, µ)** — Schem forces UTF-8 internally; if your terminal
  still mojibakes, set `LANG=…UTF-8`.  The GUI is unaffected.
- **`schem: command not found`** — use `./bin/schem` (with the path) or add
  `bin/` to your PATH.
