/* SPDX-License-Identifier: Apache-2.0
 * Test-only exact sample and original colour/alpha metadata oracle.
 * Uses pinned libjxl; never linked into the production package. */
#include <jxl/decode.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *read_bounded(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END)) { fclose(file); return NULL; }
    long size = ftell(file);
    if (size <= 0 || size > 1024 * 1024 || fseek(file, 0, SEEK_SET)) { fclose(file); return NULL; }
    unsigned char *data = malloc((size_t)size);
    if (!data) { fclose(file); return NULL; }
    *length = fread(data, 1, (size_t)size, file);
    fclose(file);
    if (*length != (size_t)size) { free(data); return NULL; }
    return data;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    size_t input_size = 0, expected_size = 0, output_size = 0;
    unsigned char *input = read_bounded(argv[1], &input_size);
    unsigned char *expected = read_bounded(argv[2], &expected_size), *output = NULL;
    JxlDecoder *dec = JxlDecoderCreate(NULL);
    int result = 1, complete = 0, colour_seen = 0, info_seen = 0;
    JxlBasicInfo info;
    JxlColorEncoding colour;
    if (!input || !expected || !dec) goto done;
    if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
        JxlDecoderSetUnpremultiplyAlpha(dec, JXL_FALSE) != JXL_DEC_SUCCESS ||
        JxlDecoderSetInput(dec, input, input_size) != JXL_DEC_SUCCESS) goto done;
    JxlDecoderCloseInput(dec);
    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec);
        if (status == JXL_DEC_BASIC_INFO) {
            if (info_seen++ || JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS ||
                info.have_animation || info.xsize > 1024 || info.ysize > 1024 ||
                info.bits_per_sample > 16 || info.exponent_bits_per_sample ||
                info.num_extra_channels > 1) goto done;
        } else if (status == JXL_DEC_COLOR_ENCODING) {
            if (colour_seen++ || JxlDecoderGetColorAsEncodedProfile(dec,
                JXL_COLOR_PROFILE_TARGET_ORIGINAL, &colour) != JXL_DEC_SUCCESS) goto done;
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            if (!info_seen || output) goto done;
            JxlPixelFormat format = {info.num_color_channels + (info.alpha_bits != 0), JXL_TYPE_UINT16, JXL_LITTLE_ENDIAN, 0};
            JxlBitDepth depth = {JXL_BIT_DEPTH_FROM_CODESTREAM, 0, 0};
            if (JxlDecoderImageOutBufferSize(dec, &format, &output_size) != JXL_DEC_SUCCESS ||
                output_size != expected_size) goto done;
            output = malloc(output_size);
            if (!output || JxlDecoderSetImageOutBuffer(dec, &format, output, output_size) != JXL_DEC_SUCCESS ||
                JxlDecoderSetImageOutBitDepth(dec, &depth) != JXL_DEC_SUCCESS) goto done;
        } else if (status == JXL_DEC_FULL_IMAGE) {
            if (complete++) goto done;
        } else if (status == JXL_DEC_SUCCESS) {
            if (complete != 1 || !colour_seen || !output || memcmp(output, expected, output_size)) goto done;
            printf("{\"width\":%u,\"height\":%u,\"bits\":%u,\"channels\":%u,\"premultiplied\":%d,\"renderingIntent\":%d,\"transferFunction\":%d}\n",
                info.xsize, info.ysize, info.bits_per_sample, info.num_color_channels + (info.alpha_bits != 0),
                info.alpha_premultiplied, colour.rendering_intent, colour.transfer_function);
            result = 0; break;
        } else goto done;
    }
done:
    if (dec) JxlDecoderDestroy(dec);
    free(input); free(expected); free(output);
    return result;
}
