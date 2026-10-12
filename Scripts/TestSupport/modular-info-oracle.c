/* SPDX-License-Identifier: Apache-2.0
 * Test-only independent libjxl header oracle; never linked into SwiftJXL.
 * Build: cc -I<include> modular-info-oracle.c -L<lib> -ljxl -o modular-info-oracle
 */
#include <jxl/decode.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return 2; }
    long length = ftell(file);
    if (length <= 0 || length > 64 * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return 2; }
    unsigned char *input = malloc((size_t)length);
    if (!input) { fclose(file); return 2; }
    size_t count = fread(input, 1, (size_t)length, file);
    fclose(file);
    if (count != (size_t)length) { free(input); return 2; }
    JxlDecoder *decoder = JxlDecoderCreate(NULL);
    if (!decoder) { free(input); return 2; }
    int result = 1;
    if (JxlDecoderSubscribeEvents(decoder, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS ||
        JxlDecoderSetInput(decoder, input, count) != JXL_DEC_SUCCESS) goto done;
    JxlDecoderCloseInput(decoder);
    JxlBasicInfo info;
    if (JxlDecoderProcessInput(decoder) != JXL_DEC_BASIC_INFO ||
        JxlDecoderGetBasicInfo(decoder, &info) != JXL_DEC_SUCCESS) goto done;
    if (JxlDecoderProcessInput(decoder) != JXL_DEC_COLOR_ENCODING) goto done;
    JxlColorEncoding colour;
    if (JxlDecoderGetColorAsEncodedProfile(decoder, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &colour) != JXL_DEC_SUCCESS) goto done;
    printf("{\"width\":%u,\"height\":%u,\"bits\":%u,\"colourChannels\":%u,\"alphaBits\":%u,\"premultiplied\":%d,\"renderingIntent\":%d,\"transferFunction\":%d}\n",
        info.xsize, info.ysize, info.bits_per_sample, info.num_color_channels,
        info.alpha_bits, info.alpha_premultiplied, colour.rendering_intent, colour.transfer_function);
    result = 0;
done:
    JxlDecoderDestroy(decoder);
    free(input);
    return result;
}
