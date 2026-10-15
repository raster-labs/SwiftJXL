/* SPDX-License-Identifier: Apache-2.0
 * Independent hardware evidence. Compile/run only on ARM in validation phase.
 * Covers every significand estimate bin at every integer exponent, sign, and
 * neighbours at bin boundaries, including Float32 rounding above 2^24.
 * clang -O2 reciprocal-vectors.c -o reciprocal-vectors
 * ./reciprocal-vectors > reciprocal-vectors.json
 */
#include <arm_neon.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
static int first = 1;
static void emit(int32_t value) {
    float input = (float)value;
    float output = vget_lane_f32(vrecpe_f32(vdup_n_f32(input)), 0);
    uint32_t bits;
    memcpy(&bits, &output, sizeof(bits));
    printf("%s[%d,%u]", first ? "" : ",\n", value, bits);
    first = 0;
}
int main(void) {
    puts("[");
    for (unsigned exponent = 1; exponent <= 30; ++exponent) {
        for (unsigned bin = 0; bin < 256; ++bin) {
            int64_t boundary = (INT64_C(1) << exponent)
                + ((INT64_C(1) << exponent) * bin) / 256;
            for (int delta = -1; delta <= 1; ++delta) {
                int64_t value = boundary + delta;
                if (value >= 2 && value <= INT32_MAX) {
                    emit((int32_t)value); emit((int32_t)-value);
                }
            }
        }
    }
    emit(INT32_MAX); emit(INT32_MIN);
    puts("\n]");
    return ferror(stdout) ? 1 : 0;
}
