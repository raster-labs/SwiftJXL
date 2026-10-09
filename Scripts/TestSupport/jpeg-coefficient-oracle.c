/* SPDX-License-Identifier: Apache-2.0
 * Test-only libjpeg-turbo coefficient oracle. Never linked into SwiftJXL.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>
#define STRINGIFY_INNER(x) #x
#define STRINGIFY(x) STRINGIFY_INNER(x)
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "--version")) {
#ifdef LIBJPEG_TURBO_VERSION
        printf("libjpeg-turbo %s; JPEG_LIB_VERSION=%d\n", STRINGIFY(LIBJPEG_TURBO_VERSION), JPEG_LIB_VERSION);
#else
        printf("libjpeg JPEG_LIB_VERSION=%d\n", JPEG_LIB_VERSION);
#endif
        return 0;
    }
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 3;
    struct jpeg_decompress_struct image;
    struct jpeg_error_mgr errors;
    image.err = jpeg_std_error(&errors);
    jpeg_create_decompress(&image);
    jpeg_stdio_src(&image, file);
    if (jpeg_read_header(&image, TRUE) != JPEG_HEADER_OK) return 4;
    jvirt_barray_ptr *arrays = jpeg_read_coefficients(&image);
    printf("{\"width\":%u,\"height\":%u,\"components\":[", image.image_width, image.image_height);
    for (int ci = 0; ci < image.num_components; ci++) {
        jpeg_component_info *c = &image.comp_info[ci];
        if (ci) printf(",");
        printf("{\"id\":%d,\"width\":%u,\"height\":%u,\"quantisation\":[", c->component_id, c->width_in_blocks, c->height_in_blocks);
        for (int i = 0; i < DCTSIZE2; i++) printf("%s%u", i ? "," : "", c->quant_table->quantval[i]);
        printf("],\"coefficients\":[");
        int first = 1;
        for (JDIMENSION y = 0; y < c->height_in_blocks; y++) {
            JBLOCKARRAY row = image.mem->access_virt_barray((j_common_ptr)&image, arrays[ci], y, 1, FALSE);
            for (JDIMENSION x = 0; x < c->width_in_blocks; x++) {
                for (int k = 0; k < DCTSIZE2; k++) {
                    printf("%s%d", first ? "" : ",", row[0][x][k]); first = 0;
                }
            }
        }
        printf("]}");
    }
    printf("]}\n");
    jpeg_finish_decompress(&image);
    jpeg_destroy_decompress(&image);
    fclose(file);
    return 0;
}
