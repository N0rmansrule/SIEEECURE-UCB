#include <string.h>
#include "types.h"
#include "benchmark.h"
#include "ascii.h"
#include "uart.h"

#define N 6
#define MAT_SIZE (1 << (N << 1))
#define DIM_SIZE (1 << N)
static float A[MAT_SIZE] = {0};
static float B[MAT_SIZE] = {0};
static float S[MAT_SIZE] = {0};

/* Computes S = AB where A, B, and S are all of 2^N x 2^N matrices. A, B, and S
 * are stored sequentially in row-major order beginning at DATA. Prints the sum
 * of the entries of S to the UART. */


uint32_t mmult() {
    float sum = 0;
    int32_t i, j, k;
    for (i = 0; i < DIM_SIZE; i++) {
        for (j = 0; j < DIM_SIZE; j++) {
            float* s = S + (i << N) + j;
            *s = 0;
            for (k = 0; k < DIM_SIZE; k++) {
                float a = *(A + (i << N) + k);
                float b = *(B + (k << N) + j);
                float prod = a * b;
                *s = *s + prod;
            }
            sum += *s;
        }
    }
    uint32_t sum_int;
    memcpy(&sum_int, &sum, 4);
    return sum_int;
}

void generate_matrices() {
    int32_t i, j;
    for (i = 0; i < DIM_SIZE; i++) {
        for (j = 0; j < DIM_SIZE; j++) {
            *(A + (i << N) + j) = (i == j) ? 1.0f : 0.0f;
        }
    }
    for (i = 0; i < DIM_SIZE; i++) {
        for (j = 0; j < DIM_SIZE; j++) {
            *(B + (i << N) + j) = j * 1.0f;
        }
    }
}


typedef void (*entry_t)(void);

int main(int argc, char**argv) {
    generate_matrices();
    run_and_time(&mmult);
    // go back to the bios - using this function causes a jr to the addr,
    // the compiler "jals" otherwise and then cannot set PC[31:28]
    uint32_t bios = ascii_hex_to_uint32("40000000");
    entry_t start = (entry_t) (bios);
    start();
    return 0;
}
