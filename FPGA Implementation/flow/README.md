# Open-source ECP5 Flow (Yosys + nextpnr-ecp5 + Project Trellis)

This repo targets **LFE5U-85F-6BG381C** (ECP5-85K class), **CABGA381**, speed **6**.

## Quick start

1. Install tools:
   - `yosys`
   - `nextpnr-ecp5`
   - `ecppack` (Project Trellis)
   - `openFPGALoader` (programming, recommended)

2. Copy and edit constraints:
   - `constraints/ecp5_bg381_template.lpf`
   - Set correct pins for your board (clk, reset, UART pins, LEDs, ...)

3. Build:
   ```bash
   ./flow/check_tools.sh
   ./flow/build_ecp5_oss.sh
   ```

   Output bitstream:
   - `build/soc_top.bit` (default TOP is `soc_top`)
   - You can override TOP:
     ```bash
     TOP=ecp5_top ./flow/build_ecp5_oss.sh
     ```

4. Program (SRAM):
   ```bash
   BOARD=<your_board> ./flow/program_ecp5_sram.sh build/soc_top.bit
   ```

   Program flash:
   ```bash
   BOARD=<your_board> ./flow/program_ecp5_flash.sh build/soc_top.bit
   ```

## Notes

- This repo includes a small memory model (`rtl/mem/simple_ram.sv`) that can be synthesized for small demos,
  but for larger programs you will want external RAM (DDR/HyperRAM/PSRAM) + a controller.
