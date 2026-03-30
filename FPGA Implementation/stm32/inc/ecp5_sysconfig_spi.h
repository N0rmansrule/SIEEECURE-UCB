// -----------------------------------------------------------------------------
// ECP5 sysCONFIG (Slave SPI) programmer helper for STM32
//
// This is a *reference* implementation, intended to be easy to read.
// You must adapt GPIO pin names, SPI instance, delays, and timeouts
// for your specific STM32 family and HAL/LL setup.
//
// The command bytes are taken from Linux' lattice-sysconfig.h.
// See docs/STM32_ECP5_CONTROL.md for the overall wiring + boot flow.
// -----------------------------------------------------------------------------
#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Return codes
typedef enum {
    ECP5_OK = 0,
    ECP5_ERR_TIMEOUT = -1,
    ECP5_ERR_SPI = -2,
    ECP5_ERR_STATUS = -3,
} ecp5_status_t;

// Hooks you must provide (HAL, LL, or bare-metal).
// These are declared as weak in the .c file so you can override them.
void ecp5_delay_us(uint32_t us);
uint32_t ecp5_millis(void);

// Board-specific GPIO controls (implement in your project)
void ecp5_gpio_set_programn(int level); // 0=assert low (reset/program), 1=deassert high
int  ecp5_gpio_get_initn(void);         // read INITN (1=high)
int  ecp5_gpio_get_done(void);          // read DONE (1=high)

void ecp5_spi_cs(int level);            // 0=CS asserted (low), 1=CS deasserted (high)
int  ecp5_spi_tx(const uint8_t *buf, size_t len);
int  ecp5_spi_rx(uint8_t *buf, size_t len);
int  ecp5_spi_txrx(const uint8_t *tx, uint8_t *rx, size_t len);

// Program FPGA SRAM configuration via sysCONFIG Slave SPI port.
// `bitstream` must point to the *uncompressed* .bit file bytes.
ecp5_status_t ecp5_sysconfig_program(const uint8_t *bitstream, size_t len);

#ifdef __cplusplus
} // extern "C"
#endif
