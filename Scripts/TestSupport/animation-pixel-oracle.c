/* SPDX-License-Identifier: Apache-2.0. Test-only libjxl all-frame oracle. */
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  FILE *in = fopen(argv[1], "rb");
  if (!in || fseek(in, 0, SEEK_END)) return 3;
  long length = ftell(in);
  if (length <= 0 || length > 64 * 1024 * 1024 || fseek(in, 0, SEEK_SET)) return 4;
  unsigned char *data = malloc((size_t)length);
  if (!data || fread(data, 1, (size_t)length, in) != (size_t)length) return 5;
  fclose(in);
  FILE *out = fopen(argv[2], "wb");
  JxlDecoder *decoder = JxlDecoderCreate(NULL);
  if (!out || !decoder) return 6;
  if (JxlDecoderSetCoalescing(decoder, JXL_TRUE) != JXL_DEC_SUCCESS ||
      JxlDecoderSubscribeEvents(decoder, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING |
          JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
      JxlDecoderSetInput(decoder, data, (size_t)length) != JXL_DEC_SUCCESS) return 7;
  JxlDecoderCloseInput(decoder);
  JxlBasicInfo info;
  JxlPixelFormat format = {3, JXL_TYPE_FLOAT, JXL_LITTLE_ENDIAN, 0};
  float *pixels = NULL;
  size_t size = 0;
  unsigned frames = 0;
  for (;;) {
    JxlDecoderStatus status = JxlDecoderProcessInput(decoder);
    if (status == JXL_DEC_BASIC_INFO) {
      if (JxlDecoderGetBasicInfo(decoder, &info) != JXL_DEC_SUCCESS ||
          !info.xsize || !info.ysize || info.xsize > 2048 || info.ysize > 2048 ||
          (info.bits_per_sample != 8 && info.bits_per_sample != 16) ||
          (info.num_color_channels != 1 && info.num_color_channels != 3) || info.num_extra_channels > 1) return 8;
      format.num_channels = info.num_color_channels + info.num_extra_channels;
      printf("image %u %u %u %u\n", info.xsize, info.ysize, format.num_channels, info.bits_per_sample);
      printf("clock %u/%u loops %u\n", info.animation.tps_numerator,
          info.animation.tps_denominator, info.animation.num_loops);
    } else if (status == JXL_DEC_COLOR_ENCODING) {
      JxlColorEncoding colour;
      JxlColorEncodingSetToSRGB(&colour, info.num_color_channels == 1);
      if (JxlDecoderSetPreferredColorProfile(decoder, &colour) != JXL_DEC_SUCCESS) return 9;
    } else if (status == JXL_DEC_FRAME) {
      JxlFrameHeader header;
      if (frames >= 8 || JxlDecoderGetFrameHeader(decoder, &header) != JXL_DEC_SUCCESS) return 10;
      printf("frame %u duration %u last %d\n", frames, header.duration, header.is_last);
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      if (JxlDecoderImageOutBufferSize(decoder, &format, &size) != JXL_DEC_SUCCESS ||
          size != (size_t)info.xsize * info.ysize * format.num_channels * sizeof(float)) return 11;
      free(pixels);
      pixels = malloc(size);
      if (!pixels || JxlDecoderSetImageOutBuffer(decoder, &format, pixels, size) != JXL_DEC_SUCCESS) return 12;
    } else if (status == JXL_DEC_FULL_IMAGE) {
      if (!pixels || frames >= 8 || fwrite(pixels, 1, size, out) != size) return 13;
      ++frames;
    } else if (status == JXL_DEC_SUCCESS) break;
    else return 14;
  }
  JxlDecoderDestroy(decoder);
  free(pixels);
  free(data);
  return fclose(out) || !frames ? 15 : 0;
}
