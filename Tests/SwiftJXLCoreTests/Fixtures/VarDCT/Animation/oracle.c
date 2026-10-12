/* SPDX-License-Identifier: Apache-2.0. Test-only scalar libjxl all-frame oracle. */
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv){
 if(argc!=3)return 2;FILE *in=fopen(argv[1],"rb");if(!in)return 3;
 fseek(in,0,SEEK_END);long n=ftell(in);rewind(in);if(n<=0||n>100000)return 4;
 unsigned char *data=malloc(n);if(!data||fread(data,1,n,in)!=(size_t)n)return 5;fclose(in);
 FILE*out=fopen(argv[2],"wb");if(!out)return 6;
 JxlDecoder*d=JxlDecoderCreate(NULL);if(!d)return 7;
 if(JxlDecoderSetCoalescing(d,JXL_TRUE)!=JXL_DEC_SUCCESS||JxlDecoderSubscribeEvents(d,JXL_DEC_BASIC_INFO|JXL_DEC_COLOR_ENCODING|JXL_DEC_FRAME|JXL_DEC_FULL_IMAGE)!=JXL_DEC_SUCCESS||JxlDecoderSetInput(d,data,n)!=JXL_DEC_SUCCESS)return 8;
 JxlDecoderCloseInput(d);JxlBasicInfo info;JxlPixelFormat fmt={3,JXL_TYPE_FLOAT,JXL_LITTLE_ENDIAN,0};float* pixels=NULL;size_t size=0;int count=0;
 for(;;){JxlDecoderStatus s=JxlDecoderProcessInput(d);
  if(s==JXL_DEC_BASIC_INFO){if(JxlDecoderGetBasicInfo(d,&info)!=JXL_DEC_SUCCESS||info.xsize!=16||info.ysize!=9||(info.bits_per_sample!=8&&info.bits_per_sample!=16)||info.num_extra_channels>1)return 9;fmt.num_channels=info.num_color_channels+info.num_extra_channels;printf("clock %u/%u loops %u\n",info.animation.tps_numerator,info.animation.tps_denominator,info.animation.num_loops);}
  else if(s==JXL_DEC_COLOR_ENCODING){JxlColorEncoding c;JxlColorEncodingSetToSRGB(&c,info.num_color_channels==1);if(JxlDecoderSetPreferredColorProfile(d,&c)!=JXL_DEC_SUCCESS)return 10;}
  else if(s==JXL_DEC_FRAME){JxlFrameHeader f;if(JxlDecoderGetFrameHeader(d,&f)!=JXL_DEC_SUCCESS)return 11;printf("frame %d duration %u last %d\n",count,f.duration,f.is_last);}
  else if(s==JXL_DEC_NEED_IMAGE_OUT_BUFFER){if(JxlDecoderImageOutBufferSize(d,&fmt,&size)!=JXL_DEC_SUCCESS||size!=16*9*fmt.num_channels*sizeof(float))return 12;free(pixels);pixels=malloc(size);if(!pixels||JxlDecoderSetImageOutBuffer(d,&fmt,pixels,size)!=JXL_DEC_SUCCESS)return 13;}
  else if(s==JXL_DEC_FULL_IMAGE){if(fwrite(pixels,1,size,out)!=size)return 14;count++;}
  else if(s==JXL_DEC_SUCCESS)break;else return 15;
 }
 JxlDecoderDestroy(d);free(pixels);free(data);if(fclose(out)||count!=3)return 16;return 0;
}
