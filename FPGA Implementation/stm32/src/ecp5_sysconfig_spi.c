// -----------------------------------------------------------------------------
// ECP5 sysCONFIG (Slave SPI) programmer helper for STM32
//
// This follows the Linux FPGA Manager sequence at a high level:
//   1) PROGRAMN toggle to enter program mode
//   2) ISC_ENABLE, ISC_ERASE
//   3) LSC_INIT_ADDR
//   4) LSC_BITSTREAM_BURST + stream the .bit bytes
//   5) Poll status, ISC_DISABLE
//
// References for command bytes and sequencing are in docs/STM32_ECP5_CONTROL.md.
// -----------------------------------------------------------------------------
#include "ecp5_sysconfig_spi.h"

// sysCONFIG command words (4 bytes each)
#define SYSCONFIG_ISC_ENABLE         0xC6
#define SYSCONFIG_ISC_DISABLE        0x26
#define SYSCONFIG_ISC_ERASE          0x0E
#define SYSCONFIG_LSC_READ_STATUS    0x3C
#define SYSCONFIG_LSC_CHECK_BUSY     0xF0
#define SYSCONFIG_LSC_REFRESH        0x79
#define SYSCONFIG_LSC_INIT_ADDR      0x46
#define SYSCONFIG_LSC_BITSTREAM_BURST 0x7A

// Status bits (from Linux lattice-sysconfig.h)
#define STATUS_DONE_BIT   (1u << 8)
#define STATUS_BUSY_BIT   (1u << 12)
#define STATUS_FAIL_BIT   (1u << 13)
#define STATUS_ERR_MASK   (0x7u << 23)

// Timeouts (tune for your board; conservative defaults)
#define TMO_INITN_MS      200
#define TMO_DONE_MS       500
#define TMO_BUSY_MS       1000

// Chunk size for burst writes (tradeoff: RAM vs speed)
#define BURST_CHUNK_BYTES 512

// Weak default hooks (override in your project)
__attribute__((weak)) void ecp5_delay_us(uint32_t us) { (void)us; }
__attribute__((weak)) uint32_t ecp5_millis(void) { return 0; }

// Helpers
static int cmd_write4(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3)
{
    uint8_t cmd[4] = { b0, b1, b2, b3 };
    ecp5_spi_cs(0);
    int rc = ecp5_spi_tx(cmd, sizeof(cmd));
    ecp5_spi_cs(1);
    return rc;
}

static int cmd_read_status_u32_be(uint32_t *out_status)
{
    // Send 4-byte command, then read 4 bytes response (big-endian)
    uint8_t cmd[4] = { SYSCONFIG_LSC_READ_STATUS, 0x00, 0x00, 0x00 };
    uint8_t rx[4]  = {0};

    ecp5_spi_cs(0);
    int rc = ecp5_spi_tx(cmd, sizeof(cmd));
    if (rc) { ecp5_spi_cs(1); return rc; }
    rc = ecp5_spi_rx(rx, sizeof(rx));
    ecp5_spi_cs(1);
    if (rc) return rc;

    *out_status = ((uint32_t)rx[0] << 24) |
                  ((uint32_t)rx[1] << 16) |
                  ((uint32_t)rx[2] <<  8) |
                  ((uint32_t)rx[3] <<  0);
    return 0;
}

static int cmd_read_busy_u8(uint8_t *busy)
{
    // 4-byte command, 1-byte response
    uint8_t cmd[4] = { SYSCONFIG_LSC_CHECK_BUSY, 0x00, 0x00, 0x00 };
    uint8_t rx = 0;

    ecp5_spi_cs(0);
    int rc = ecp5_spi_tx(cmd, sizeof(cmd));
    if (rc) { ecp5_spi_cs(1); return rc; }
    rc = ecp5_spi_rx(&rx, 1);
    ecp5_spi_cs(1);
    if (rc) return rc;

    *busy = rx;
    return 0;
}

static ecp5_status_t poll_initn_high(void)
{
    uint32_t t0 = ecp5_millis();
    while ((ecp5_millis() - t0) < TMO_INITN_MS) {
        if (ecp5_gpio_get_initn()) return ECP5_OK;
    }
    return ECP5_ERR_TIMEOUT;
}

static ecp5_status_t poll_done_high(void)
{
    uint32_t t0 = ecp5_millis();
    while ((ecp5_millis() - t0) < TMO_DONE_MS) {
        if (ecp5_gpio_get_done()) return ECP5_OK;
    }
    return ECP5_ERR_TIMEOUT;
}

static ecp5_status_t poll_busy_clear(void)
{
    uint32_t t0 = ecp5_millis();
    while ((ecp5_millis() - t0) < TMO_BUSY_MS) {
        uint8_t busy = 0xFF;
        if (cmd_read_busy_u8(&busy)) return ECP5_ERR_SPI;
        if (busy == 0) return ECP5_OK;
        ecp5_delay_us(30); // Linux driver polls ~30us interval
    }
    return ECP5_ERR_TIMEOUT;
}

static ecp5_status_t burst_write_bitstream(const uint8_t *data, size_t len)
{
    // Send BITSTREAM_BURST command, then stream bitstream bytes.
    // We keep CS asserted during the command+data to match a typical burst.
    uint8_t cmd[4] = { SYSCONFIG_LSC_BITSTREAM_BURST, 0x00, 0x00, 0x00 };

    ecp5_spi_cs(0);
    if (ecp5_spi_tx(cmd, sizeof(cmd))) { ecp5_spi_cs(1); return ECP5_ERR_SPI; }

    size_t off = 0;
    while (off < len) {
        size_t n = len - off;
        if (n > BURST_CHUNK_BYTES) n = BURST_CHUNK_BYTES;
        if (ecp5_spi_tx(data + off, n)) { ecp5_spi_cs(1); return ECP5_ERR_SPI; }
        off += n;
    }

    ecp5_spi_cs(1);
    return ECP5_OK;
}

ecp5_status_t ecp5_sysconfig_program(const uint8_t *bitstream, size_t len)
{
    if (!bitstream || len == 0) return ECP5_ERR_STATUS;

    // 1) Force reconfiguration using PROGRAMN
    // PROGRAMN is active-low, has internal pull-up (still add external pull-up).
    ecp5_gpio_set_programn(0);
    ecp5_delay_us(1000);
    ecp5_gpio_set_programn(1);

    // Wait for INITN to indicate the device is ready (INITN is open-drain, needs pull-up).
    if (poll_initn_high() != ECP5_OK) return ECP5_ERR_TIMEOUT;

    // 2) Enter ISC mode (ISC_ENABLE, then ISC_ERASE)
    if (cmd_write4(SYSCONFIG_ISC_ENABLE, 0x00, 0x00, 0x00)) return ECP5_ERR_SPI;
    if (poll_busy_clear() != ECP5_OK) return ECP5_ERR_TIMEOUT;

    // ISC_ERASE uses second byte = 0x01 in Linux
    if (cmd_write4(SYSCONFIG_ISC_ERASE, 0x01, 0x00, 0x00)) return ECP5_ERR_SPI;
    if (poll_busy_clear() != ECP5_OK) return ECP5_ERR_TIMEOUT;

    // 3) Initialize address shift register
    if (cmd_write4(SYSCONFIG_LSC_INIT_ADDR, 0x00, 0x00, 0x00)) return ECP5_ERR_SPI;

    // 4) Burst write the bitstream
    if (burst_write_bitstream(bitstream, len) != ECP5_OK) return ECP5_ERR_SPI;

    // 5) Wait for internal busy to clear and DONE to go high
    if (poll_busy_clear() != ECP5_OK) return ECP5_ERR_TIMEOUT;

    // Optionally also check the sysCONFIG status word
    uint32_t status = 0;
    if (cmd_read_status_u32_be(&status)) return ECP5_ERR_SPI;

    if (status & STATUS_FAIL_BIT) return ECP5_ERR_STATUS;
    if (status & STATUS_ERR_MASK) return ECP5_ERR_STATUS;

    // Disable ISC (finishes programming)
    if (cmd_write4(SYSCONFIG_ISC_DISABLE, 0x00, 0x00, 0x00)) return ECP5_ERR_SPI;

    // DONE pin check (if wired)
    if (poll_done_high() != ECP5_OK) {
        // If DONE isn't wired, you can ignore this. Keep as a warning/failure for now.
        return ECP5_ERR_TIMEOUT;
    }

    return ECP5_OK;
}
