# SIEEECURE RV64 7‑Stage Core (Educational / FPGA Target)

This repository contains a compact **in‑order RV64** core with a staged pipeline and a minimal SoC wrapper.

**Core features**
- RV64I + M (mul/div/rem)
- Machine‑mode CSRs (subset) + trap/mret plumbing
- Branch predictor: BHT (2‑bit) + BTB + small RAS
- I$ / D$ (16‑byte line, direct‑mapped, blocking)
- Simple memory arbiter (D$ priority)
- Custom **SIEEECURE** encrypted‑register instructions:
  - `SE.RTYPE` (ciphertext ALU ops via AES‑based keystream)
  - `SE.LD` / `SE.SD` (load/store 128‑bit ciphertext blocks)
- A small FP64 unit used by SE ops (replace with IEEE‑754 IP for production)

**FPGA target**
- Lattice ECP5 (LFE5U‑85F‑6BG381C / CABGA381 / speed 6)
- Open-source flow: Yosys + nextpnr‑ecp5 + Project Trellis + openFPGALoader

> This is an educational project, not a complete production‑quality RISC‑V implementation.

## Directory layout

- `rtl/core/` — core pipeline and common units (ALU, decode, CSR, regfiles, etc.)
- `rtl/se/` — SIEEECURE AES/SE unit
- `rtl/cache/` — icache, dcache, arbiter
- `rtl/bp/` — branch predictor
- `rtl/bus/` — `simple_mem_if` interface
- `rtl/mem/` — `simple_ram` memory model (simulation / small FPGA demo)
- `rtl/soc/` — `soc_top` wrapper (simulation) and `ecp5_top` (FPGA-friendly top)
- `tb/` — testbenches (SoC + unit tests)
- `flow/` — open-source ECP5 build/program scripts
- `constraints/` — LPF templates (you must fill pins)
- `instructions/` — opcode/encoding reference text files
- `firmware/` — optional example program and script to generate `program.hex`
- `tools/` — helpers (`bin2bytehex.py`, `elf2hex.sh`)

## Simulation

Requires a SystemVerilog simulator (examples use iverilog).

```bash
make sim TB=tb/tb_soc.sv
./simv +MEMHEX=program.hex
```

Unit tests (example):
```bash
make sim TB=tb/tb_alu.sv
./simv
```

The RAM model (`rtl/mem/simple_ram.sv`) supports loading a byte‑per‑line hex file:
- parameter `INIT_HEX`, or
- runtime plusarg: `+MEMHEX=program.hex`

## FPGA build/program (ECP5 open-source flow)

See:
- `docs/ECP5_LFE5U-85F_BUILD_PROGRAM.md`
- `flow/README.md`

Quick start:
```bash
./flow/check_tools.sh
./flow/build_ecp5_oss.sh
```

Build `ecp5_top` instead of `soc_top`:
```bash
TOP=ecp5_top LPF=constraints/ecp5_bg381_minimal.lpf ./flow/build_ecp5_oss.sh
```

## Instruction opcode references

- `instructions/RV64I_OPCODES.txt`
- `instructions/SIEEECURE_SE_OPCODES.txt`


## Added secure-entropy / SE-GPU / RTL-Tetris blocks

- `rtl/se/entropy_source_mux.sv` — selects QRNG, photonic, or mixed entropy streams
- `rtl/se/entropy_conditioner.sv` — small FPGA-friendly key extractor / conditioner
- `rtl/se/se_key_manager.sv` — drives shared external SE key/seed domain
- `rtl/gpu/se_gpu_core.sv` — SE-aware 2D GPU command engine
- `rtl/games/tetris_rtl_system.sv` — RTL Tetris subsystem using CPU, GPU, or both
- `rtl/soc/soc_quad_secure_entropy_gpu_tetris_top.sv` — 4-core secure top with entropy select
- `rtl/soc/ecp5_quad_entropy_gpu_tetris_top.sv` — FPGA wrapper for the secure entropy/Tetris build
- `isa/GPU_PLAIN_INSTRUCTIONS.txt` / `isa/GPU_ENCRYPTED_INSTRUCTIONS.txt` — GPU command references
- `docs/ENTROPY_SELECT_QRNG_PHOTON.md` — design notes for QRNG/photon key selection
