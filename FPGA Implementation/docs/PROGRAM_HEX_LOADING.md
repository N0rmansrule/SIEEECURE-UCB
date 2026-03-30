# Loading a Program into Memory via a Text (HEX) File

The simulation SoC uses `rtl/mem/simple_ram.sv`, which is a **byte-addressed memory** model.
It supports loading a hex text file using Verilog `$readmemh`.

---

## 1) File format: `program.hex`

- The memory array is 8-bit wide, so the simplest format is:
  - **one byte per line**
  - 2 hex characters per line (00–FF)

Example (`program.hex`):
```
13
05
00
00
...
```

This loads:
- mem[0] = 0x13
- mem[1] = 0x05
- mem[2] = 0x00
- mem[3] = 0x00

Which corresponds to the little-endian bytes of 32-bit instructions.

---

## 2) Using it in simulation (recommended)

### With Icarus Verilog:
```
make sim
./simv +MEMHEX=program.hex
```

### Or set it as a parameter in `soc_top`:
- `MEM_INIT_HEX="program.hex"`

---

## 3) Producing `program.hex` from firmware

A typical bare-metal flow:

1) Compile/link firmware for RV64:
   - use a RISC‑V GCC toolchain (e.g. `riscv64-unknown-elf-gcc`)
   - target: `-march=rv64im_zicsr_zifencei -mabi=lp64`

2) Convert ELF -> raw binary:
```
riscv64-unknown-elf-objcopy -O binary firmware.elf firmware.bin
```

3) Convert binary -> byte-hex text:
This repo includes:
- `tools/bin2bytehex.py`

Usage:
```
python3 tools/bin2bytehex.py firmware.bin program.hex
```

---

## 4) For FPGA (non-simulation)

To “boot” real hardware, you usually choose one of these approaches:

A) **Embed program into BRAM init** at synthesis time (simple for demos).

B) Add a **UART/SPI bootloader** that copies a program into RAM at reset.

C) Use external memory (SPI flash/DDR) and a small Boot ROM.

This repo provides the CPU and a simulation RAM model; a full MCU boot flow (UART loader, SPI flash controller, etc.) is a next integration step.

