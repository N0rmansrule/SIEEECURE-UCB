# ECP5 Build + Program Guide (LFE5U-85F-6BG381C / CABGA381 / speed 6)

This project ships as **SystemVerilog RTL** plus a small simulation SoC wrapper (`rtl/soc/soc_top.sv`).

To run on real hardware you will:
1) Choose a toolchain (Lattice Diamond or open-source Yosys/nextpnr/prjtrellis).
2) Provide a **board-specific top** (clock/reset + any I/O you want).
3) Provide a **pin constraint file** (`.lpf`) for your board.
4) Build a bitstream (`.bit`).
5) Program the FPGA (SRAM for quick test, or SPI flash for power-on boot).

---

## 0) Device settings you should use

- Device family: **Lattice ECP5**
- Device: **LFE5U-85F**
- Package: **CABGA381** (often written as BG381 / 381‑CABGA)
- Speed grade: **6**

In the open-source flow, that maps to:

- `nextpnr-ecp5 --85k --package CABGA381 --speed 6`

---

## 1) Toolchain option A: Open-source flow (Yosys + nextpnr-ecp5 + Project Trellis)

### Install (high level)
You need:
- Yosys (synthesis)
- nextpnr-ecp5 (place & route)
- Project Trellis tools (device DB + `ecppack`, `ecppll`, `ecpbram`, ...)
- A programmer: `openFPGALoader` (recommended) or Lattice Programmer

> Many people install these via an “OSS CAD Suite” bundle, or via distro packages (Linux).

### Build steps
This repo includes a helper script you can start from:

- `flow/build_ecp5_oss.sh`

Typical commands look like:

1) Synthesis -> JSON netlist:
   - `yosys -p "read_verilog -sv <rtl_files>; synth_ecp5 -top soc_top -abc9 -json build/soc_top.json"`

2) Place & route -> Trellis textcfg:
   - `nextpnr-ecp5 --85k --package CABGA381 --speed 6 --json build/soc_top.json --lpf constraints/ecp5_bg381_template.lpf --textcfg build/soc_top.config --report build/soc_top_report.json`

3) Bitstream pack:
   - `ecppack build/soc_top.config build/soc_top.bit`

### Constraints (.lpf)
Create a board-specific `.lpf` file.

This repo provides a **template** with placeholders:

- `constraints/ecp5_bg381_template.lpf`

You must replace the pin names with your board’s actual pins.

---

## 2) Toolchain option B: Lattice Diamond (vendor flow)

1) Create a new project
2) Select:
   - Family: ECP5
   - Device: LFE5U-85F
   - Package: CABGA381
   - Speed: 6
3) Add RTL sources (all `rtl/**/*.sv`) and your top module
4) Add LPF constraints
5) Run Synthesis / Map / Place&Route
6) Export bitstream (`.bit`) for programming

Diamond is the “official” route and can make timing closure easier for some designs, but the open-source flow is very capable for ECP5.

---

## 3) Programming the FPGA (JTAG) with openFPGALoader

### Program into SRAM (volatile, good for rapid iteration)
Example:
- `openFPGALoader -b <your_board> build/soc_top.bit`

### Program SPI flash (non-volatile boot image)
Example:
- `openFPGALoader -b <your_board> -f build/soc_top.bit`

If you don’t have a known board definition, you can specify a cable:
- `openFPGALoader -c <cable_name> build/soc_top.bit`

> Note: For ECP5, programming external SPI flash through JTAG uses an internal bridge to the Master SPI port.
> If the FPGA already contains a user bitstream, make sure your design leaves the Master SPI port enabled (so flash programming still works).

---

## 4) Minimal hardware top for “it runs” bring-up

The included `soc_top` has only:
- `clk`, `rst`, `ext_irq`
- `dbg_pc` output

For real boards you typically add:
- a reset button pin to `rst`
- a UART TX/RX so you can print text
- optional LEDs driven from a GPIO register

---

## 5) Timing closure tips for ECP5 85k

- Keep the core clock realistic first (e.g. 25–50 MHz) then push higher.
- Use BRAM (EBR) for caches/memories.
- Try `synth_ecp5 -abc9` for better mapping.
- Make sure your clock constraint is correct (`FREQUENCY PORT "clk" <freq>;` in LPF).


---

## 6) Using an STM32 as the FPGA configuration controller

If your board uses an STM32 to configure the ECP5 directly (Slave SPI sysCONFIG) or to update the configuration flash, see:

- `docs/STM32_ECP5_CONTROL.md`

## Quad-core + Tetris GPU build (new top)

This project now also includes a **quad-core** top with a tiny tile-renderer GPU that plays a simplified Tetris-style demo from an internal ROM.

- RTL top module: `ecp5_quad_gpu_top`
- SoC module: `soc_quad_gpu_top`
- GPU module: `gpu_tetris_engine` (renders VGA-style RGB + HS/VS)

To build the quad-core + GPU bitstream with the open-source flow:

```bash
cd flow
TOP=ecp5_quad_gpu_top DEVICE=LFE5U-85F-6BG381C ./build_ecp5_oss.sh
```

Notes:
- The **GPU outputs VGA-style signals** (`vga_r/g/b[7:0]`, `vga_hsync`, `vga_vsync`).
- Use `constraints/ecp5_bg381_vga_template.lpf` as your starting point to map pins on your custom board.
- The default cache sizing is reduced (1KB I$ + 1KB D$ per core) to help fit in an ECP5-85K.

