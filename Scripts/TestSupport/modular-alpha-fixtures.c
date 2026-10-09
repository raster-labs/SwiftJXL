/* SPDX-License-Identifier: Apache-2.0
 * Independent libjxl associated-alpha fixture generator, test-only.
 * cc -I<include> modular-alpha-fixtures.c -L<lib> -ljxl -o modular-alpha-fixtures
 * Usage: modular-alpha-fixtures OUTPUT CHANNELS BITS
 */
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    int channels = atoi(argv[2]), bits = atoi(argv[3]);
    if ((channels != 2 && channels != 4) || (bits != 8 && bits != 12 && bits != 16)) return 2;
    const size_t width = 513, height = 3, count = width * height * channels;
    uint16_t *samples = calloc(count, sizeof(*samples));
    uint8_t *output = malloc(4 * 1024 * 1024);
    JxlEncoder *encoder = JxlEncoderCreate(NULL);
    int result = 1;
    const char *stage = "allocation";
    if (!samples || !output || !encoder) goto done;
    unsigned maximum = (1u << bits) - 1;
    for (size_t i = 0; i < width * height; ++i) {
        unsigned alpha = (i * 211) & maximum;
        for (int c = 0; c < channels; ++c) {
            unsigned value = c == channels - 1 ? alpha : alpha * (c + 1) / channels;
            if (bits == 8) ((uint8_t *)samples)[i * channels + c] = value;
            else samples[i * channels + c] = value;
        }
    }
    JxlBasicInfo info;
    JxlEncoderInitBasicInfo(&info);
    info.xsize = width; info.ysize = height; info.bits_per_sample = bits;
    info.num_color_channels = channels - 1; info.num_extra_channels = 1;
    info.alpha_bits = bits; info.alpha_premultiplied = JXL_TRUE;
    info.uses_original_profile = JXL_TRUE;
    stage = "basic info";
    if (JxlEncoderSetBasicInfo(encoder, &info) != JXL_ENC_SUCCESS) goto done;
    JxlColorEncoding colour;
    JxlColorEncodingSetToSRGB(&colour, channels == 2);
    colour.rendering_intent = JXL_RENDERING_INTENT_RELATIVE;
    stage = "colour encoding";
    if (JxlEncoderSetColorEncoding(encoder, &colour) != JXL_ENC_SUCCESS) goto done;
    JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(encoder, NULL);
    stage = "frame settings";
    if (!settings || JxlEncoderSetFrameLossless(settings, JXL_TRUE) != JXL_ENC_SUCCESS ||
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 3) != JXL_ENC_SUCCESS) goto done;
    JxlBitDepth depth = {JXL_BIT_DEPTH_FROM_CODESTREAM, 0, 0};
    stage = "input precision";
    if (JxlEncoderSetFrameBitDepth(settings, &depth) != JXL_ENC_SUCCESS) goto done;
    JxlPixelFormat format = {(uint32_t)channels, bits == 8 ? JXL_TYPE_UINT8 : JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0};
    stage = "input samples";
    if (JxlEncoderAddImageFrame(settings, &format, samples, count * (bits == 8 ? 1 : sizeof(*samples))) != JXL_ENC_SUCCESS) goto done;
    JxlEncoderCloseInput(encoder);
    uint8_t *next = output;
    size_t available = 4 * 1024 * 1024;
    stage = "compressed output";
    if (JxlEncoderProcessOutput(encoder, &next, &available) != JXL_ENC_SUCCESS) goto done;
    stage = "file output";
    FILE *file = fopen(argv[1], "wb");
    if (!file) goto done;
    size_t size = (size_t)(next - output);
    int written = fwrite(output, 1, size, file) == size;
    int closed = fclose(file) == 0;
    if (!written || !closed) goto done;
    result = 0;
done:
    if (result != 0) fprintf(stderr, "Fixture generation failed at %s (libjxl error %d)\n", stage, encoder ? JxlEncoderGetError(encoder) : -1);
    if (encoder) JxlEncoderDestroy(encoder);
    free(samples); free(output);
    return result;
}
