# Firmware examples

These are *optional* examples to help you generate a `program.hex` that can be loaded into
`rtl/mem/simple_ram.sv` for simulation (and small FPGA demos).

## Requirements
- A RISC-V 64-bit bare-metal toolchain, e.g. `riscv64-unknown-elf-gcc`
- `objcopy` (usually shipped with the toolchain)
- Python 3 (to run `tools/bin2bytehex.py`)

## Build an example `program.hex`

From repo root:

```bash
cd firmware
make
```

Outputs:
- `demo.elf`
- `demo.bin`
- `program.hex`  (byte-per-line hex for `simple_ram`)
