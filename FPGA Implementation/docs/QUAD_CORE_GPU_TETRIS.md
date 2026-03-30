Quad-Core + Tetris GPU Demo
===========================

What you get
------------
- **4x RV64** cores (`rv64_core_7stage`) with I$ + D$ each
- Shared memory behind a **round-robin arbiter**
- A small **tile-renderer GPU** that outputs VGA-style signals and plays a
  simplified Tetris-like falling-piece animation from an internal ROM.
- GPU supports both:
  - **Plain** command ROM
  - **Encrypted** command ROM (SIEEECURE-style AES keystream decryption)

Key RTL files
-------------
- CPU: `rtl/core/rv64_core_7stage.sv`
- Quad SoC: `rtl/soc/soc_quad_gpu_top.sv`
- ECP5 top: `rtl/soc/ecp5_quad_gpu_top.sv`
- Global memory arbiter: `rtl/bus/mem_arbiter4_rr.sv`
- GPU: `rtl/gpu/gpu_tetris_engine.sv`
- VGA timing: `rtl/gpu/vga_timing.sv`
- GPU ROMs:
  - `rtl/gpu/tetris_cmd_rom_plain.sv`
  - `rtl/gpu/tetris_cmd_rom_enc.sv`

GPU encryption in one sentence
------------------------------
For each command entry, the GPU computes:

  payload = enc_payload XOR AES_encrypt({seed, ctr})[63:0]

which matches the keystream-based decryption scheme used by the CPU's SE unit.

Building (open-source ECP5 flow)
--------------------------------
From the repo root:

```bash
cd flow
TOP=ecp5_quad_gpu_top DEVICE=LFE5U-85F-6BG381C ./build_ecp5_oss.sh
```

Constraints / pins
------------------
This design outputs **VGA-style** signals:

- `vga_r[7:0]`, `vga_g[7:0]`, `vga_b[7:0]`
- `vga_hsync`, `vga_vsync`

Use `constraints/ecp5_bg381_vga_template.lpf` as a starting point.

Changing the Tetris demo
------------------------
- Plain + encrypted ROM entries are also exported to:
  - `firmware/tetris_cmd_plain_128b.txt`
  - `firmware/tetris_cmd_enc_128b.txt`
- To regenerate both ROMs, run:
  ```bash
  python3 tools/gen_tetris_rom.py
  ```
