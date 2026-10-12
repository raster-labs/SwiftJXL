/* SPDX-License-Identifier: Apache-2.0. Test-only independent libjxl fixture generator. */
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv){
 if(argc!=3&&argc!=4&&argc!=6)return 2;int lossless=atoi(argv[2]);int bits=argc==6?atoi(argv[4]):8,channels=argc==6?atoi(argv[5]):3;
 JxlEncoder *e=JxlEncoderCreate(NULL);if(!e)return 3;
 JxlBasicInfo b;JxlEncoderInitBasicInfo(&b);b.xsize=16;b.ysize=9;b.bits_per_sample=bits;b.num_color_channels=channels>=3?3:1;b.num_extra_channels=channels%2==0;b.alpha_bits=b.num_extra_channels?bits:0;b.uses_original_profile=lossless;b.have_animation=JXL_TRUE;
 b.animation.tps_numerator=100;b.animation.tps_denominator=1;b.animation.num_loops=3;
 if(JxlEncoderSetBasicInfo(e,&b)!=JXL_ENC_SUCCESS)return 4;
 JxlColorEncoding col;JxlColorEncodingSetToSRGB(&col,channels<=2);if(JxlEncoderSetColorEncoding(e,&col)!=JXL_ENC_SUCCESS)return 5;
 JxlEncoderFrameSettings *s=JxlEncoderFrameSettingsCreate(e,NULL);
 if(JxlEncoderSetFrameLossless(s,lossless)!=JXL_ENC_SUCCESS)return 6;
 if(!lossless && JxlEncoderSetFrameDistance(s,1)!=JXL_ENC_SUCCESS)return 7;
 if(JxlEncoderFrameSettingsSetOption(s,JXL_ENC_FRAME_SETTING_EFFORT,3)!=JXL_ENC_SUCCESS)return 8;
 if(argc>=4&&JxlEncoderFrameSettingsSetOption(s,JXL_ENC_FRAME_SETTING_EPF,atoi(argv[3]))!=JXL_ENC_SUCCESS)return 17;
 JxlPixelFormat fmt={channels,bits==8?JXL_TYPE_UINT8:JXL_TYPE_UINT16,JXL_NATIVE_ENDIAN,0};unsigned char pixels8[16*9*4];unsigned short pixels16[16*9*4];
 for(int frame=0;frame<3;frame++){
  for(int i=0;i<16*9*channels;i++){pixels8[i]=(unsigned char)(i*7+frame*63);pixels16[i]=(unsigned short)(i*257+frame*769);}
  JxlFrameHeader h;JxlEncoderInitFrameHeader(&h);h.duration=(frame+1)*10;
  if(JxlEncoderSetFrameHeader(s,&h)!=JXL_ENC_SUCCESS||JxlEncoderAddImageFrame(s,&fmt,bits==8?(void*)pixels8:(void*)pixels16,16*9*channels*(bits/8))!=JXL_ENC_SUCCESS)return 9;
 }
 JxlEncoderCloseInput(e);unsigned char output[100000],*next=output;size_t available=sizeof(output);
 if(JxlEncoderProcessOutput(e,&next,&available)!=JXL_ENC_SUCCESS)return 10;
 FILE *f=fopen(argv[1],"wb");if(!f)return 11;size_t count=(size_t)(next-output);if(fwrite(output,1,count,f)!=count||fclose(f))return 12;
 JxlEncoderDestroy(e);return 0;
}
