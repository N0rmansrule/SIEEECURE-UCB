# STM32 <-> ECP5 Control (Reference)

This folder contains a **reference** STM32-side implementation for programming an ECP5 over the **sysCONFIG Slave SPI** port.

- `inc/ecp5_sysconfig_spi.h`
- `src/ecp5_sysconfig_spi.c`

It is designed to be *portable*: you provide the board-specific `GPIO` + `SPI` hooks.

## Typical use

1. Build the FPGA bitstream (on your PC):
   ```bash
   ./flow/build_ecp5_oss.sh
   ```

2. Export for STM32:
   ```bash
   ./flow/export_for_stm32.sh build/soc_top.bit
   # or generate a C header for embedding:
   EMBED=1 ./flow/export_for_stm32.sh build/soc_top.bit
   ```

3. In your STM32 firmware:
   - read `stm32/bitstream/ecp5_image.bit` from external flash/SD/etc **or**
   - include `stm32/bitstream/ecp5_bitstream.h` if you embedded it
   - call:
     ```c
     ecp5_sysconfig_program(ecp5_bitstream, ecp5_bitstream_len);
     ```

See `docs/STM32_ECP5_CONTROL.md` for wiring, CFG mode strapping, and gotchas.
