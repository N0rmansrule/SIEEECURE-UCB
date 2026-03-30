# STM32 controlling an ECP5 (LFE5U-85F-6BG381C) directly

This project is built for an **ECP5-85K** target. If you have a *custom board* where an **STM32 configures and manages the FPGA**, you have two realistic options:

1) **Recommended for products:** FPGA boots itself from an external SPI/QSPI flash (Master SPI).  
   The STM32 is used to *update* that flash and/or manage the FPGA after boot.

2) **Simplest BOM (no flash):** STM32 streams the FPGA bitstream over **sysCONFIG Slave SPI** every power-up.

This doc focuses on the wiring + “bring-up flow” so you can design your board and firmware once, and then iterate on the FPGA image.

---

## A) Hardware signals you should plan for (always)

Even if you intend to use STM32-only configuration, **always** add a small JTAG header (or pads) for recovery.

### Minimum “recovery/debug” pins
- JTAG: TCK, TMS, TDI, TDO (+ GND, VREF)
- `PROGRAMN` (active low reset into configuration)
- `INITN` (config status, open-drain bidirectional; needs pull-up)
- `DONE` (config done status)

---

## B) Option 1: Master SPI boot (FPGA boots from external flash)

### Why you probably want this
- FPGA config happens automatically at power-up.
- STM32 does not need to store the FPGA bitstream internally.
- Field updates are easy: STM32 re-programs the external flash.

### CFG mode strapping (CFGMDN[2:0])
Set the configuration mode pins to **Master SPI**.

According to the ECP5 sysCONFIG usage guide, CFGMDN settings select the mode:
- **MSPI = 0b010** (CFGMDN2=0, CFGMDN1=1, CFGMDN0=0)  
- **SSPI = 0b001** (CFGMDN2=0, CFGMDN1=0, CFGMDN0=1)  
(See Table 4.6 in the sysCONFIG guide.)  
Source: Lattice “ECP5 and ECP5-5G sysCONFIG Usage Guide” (FPGA‑TN‑02039). 

### SPI flash wiring
Wire a flash device (SPI/QSPI) to the ECP5 **Master SPI port** pins (in bank VCCIO8).

Important practical note: programming an external SPI flash **through JTAG** uses an internal bridge to the FPGA Master SPI port, so if you program flash via JTAG in the lab, your user design must leave the Master SPI port enabled.  
(That’s a common “why can’t I program flash anymore?” gotcha.)

### OSS flow bitstream packaging for flash boot
`ecppack` supports options for flash boot bitstreams:
- `--compress` (reduce size)
- `--spimode` (values include: `fast-read`, `dual-spi`, `qspi`)
- `--bootaddr` (multi-boot)

See `ecppack` man page for those options.

**Caution:** some setups are sensitive to `--spimode`. If you have trouble booting, try omitting `--spimode` first, then re-introduce it once you confirm the flash and mode are correct.

---

## C) Option 2: sysCONFIG Slave SPI boot (STM32 streams bitstream)

### Why you might want this
- No external flash required.
- STM32 fully controls when/how the FPGA is configured (useful for power sequencing).

### CFG mode strapping
Set CFGMDN to **SSPI = 0b001**.

### Slave SPI port signals
In SSPI mode, the sysCONFIG guide describes:
- `MCLK/CCLK` becomes **CCLK input**
- `MOSI` is input
- `MISO` is output
- `SN` is an **active-low** input (chip select)
- `HOLDN` is input (has weak pull-up)

So your STM32 connects its SPI:
- SCK -> CCLK
- MOSI -> MOSI
- MISO <- MISO
- NSS/CS -> SN

…and also connects to:
- `PROGRAMN` (to start a fresh configuration)
- `INITN` + `DONE` (status)

### INITN electrical note (important for a custom board)
`INITN` is an **open-drain bidirectional pin** and should be pulled high externally. It indicates the end of initialization and is used for configuration-mode sampling.  

That means:
- Put a pull-up resistor on INITN.
- If STM32 drives it, do so as open-drain or via a transistor/OD buffer.

### Bitstream format / what to send
When programming ECP5 over sysCONFIG SSPI, the **uncompressed** `.bit` image is written to configuration SRAM.

That means:
- Don’t use bitstream compression for this path.
- Stream the `.bit` bytes exactly as produced by `ecppack`.

### Reference STM32 code
See:
- `stm32/src/ecp5_sysconfig_spi.c`
- `stm32/inc/ecp5_sysconfig_spi.h`

The command bytes in that code come from Linux’ `lattice-sysconfig.h` definitions, and the programming sequence follows the Linux FPGA Manager high-level order.

---

## D) “Uploading a program.hex” when you have an STM32

The FPGA **configuration bitstream** and the CPU **firmware** are separate things.

### Development-friendly approach
- During early bring-up: embed `program.hex` into BRAM/init at synthesis time.
- Iterate quickly in simulation.

### MCU-style approach (recommended long-term)
Have the STM32 act as the *boot controller*:
1) Configure FPGA (MSPI flash boot or SSPI streaming).
2) Hold CPU in reset.
3) Load firmware into RAM (UART/SPI “loader” peripheral) or into external memory.
4) Release CPU reset.

This repo includes a simulation-friendly `program.hex` loader (`docs/PROGRAM_HEX_LOADING.md`) and provides the RTL blocks to integrate a loader, but the exact peripheral/boot ROM strategy depends on your board choices (RAM/flash sizes, interface choice, etc.).
