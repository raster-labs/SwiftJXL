/* SPDX-License-Identifier: Apache-2.0
 * Test-only libjxl pixel oracle. Decode in explicit sRGB sample space.
 */
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char *read_file(const char *p,size_t *n) {
 FILE *f=fopen(p,"rb");if(!f)return NULL;
 if(fseek(f,0,SEEK_END)){fclose(f);return NULL;}long s=ftell(f);
 if(s<=0||s>32*1024*1024||fseek(f,0,SEEK_SET)){fclose(f);return NULL;}
 unsigned char *b=malloc((size_t)s);if(!b){fclose(f);return NULL;}
 *n=fread(b,1,(size_t)s,f);fclose(f);if(*n!=(size_t)s){free(b);return NULL;}return b;
}
static int write_file(const char *p,const void *b,size_t n) {
 FILE *f=fopen(p,"wb");if(!f)return 1;int ok=fwrite(b,1,n,f)==n;return fclose(f)||!ok;
}
int main(int argc,char **argv) {
 if(argc<4)return 2;size_t n=0;unsigned char *in=read_file(argv[2],&n);if(!in)return 2;
 int result=1;
 if((!strcmp(argv[1],"decode") || !strcmp(argv[1],"decode-float"))) {
  JxlDecoder *d=JxlDecoderCreate(NULL);unsigned char *out=NULL;size_t bytes=0;
  if(!d)goto end;
  if(JxlDecoderSubscribeEvents(d,JXL_DEC_BASIC_INFO|JXL_DEC_COLOR_ENCODING|JXL_DEC_FULL_IMAGE)!=JXL_DEC_SUCCESS||JxlDecoderSetInput(d,in,n)!=JXL_DEC_SUCCESS)goto dec_end;
  JxlDecoderCloseInput(d);JxlBasicInfo info;JxlPixelFormat fmt;
  for(;;) {
   JxlDecoderStatus s=JxlDecoderProcessInput(d);
   if(s==JXL_DEC_BASIC_INFO) {
    if(JxlDecoderGetBasicInfo(d,&info)!=JXL_DEC_SUCCESS||info.xsize>1024||info.ysize>1024||(info.bits_per_sample!=8&&info.bits_per_sample!=16)||info.num_extra_channels>1)break;
    fmt=(JxlPixelFormat){info.num_color_channels+(info.alpha_bits>0),!strcmp(argv[1],"decode-float")?JXL_TYPE_FLOAT:(info.bits_per_sample==8?JXL_TYPE_UINT8:JXL_TYPE_UINT16),JXL_LITTLE_ENDIAN,0};
   } else if(s==JXL_DEC_COLOR_ENCODING) {
    JxlColorEncoding col;JxlColorEncodingSetToSRGB(&col,info.num_color_channels==1); if(argc>4 && !strcmp(argv[4],"linear")) col.transfer_function=JXL_TRANSFER_FUNCTION_LINEAR;
    if(JxlDecoderSetPreferredColorProfile(d,&col)!=JXL_DEC_SUCCESS)break;
   } else if(s==JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
    if(JxlDecoderImageOutBufferSize(d,&fmt,&bytes)!=JXL_DEC_SUCCESS||bytes>16*1024*1024||out)break;
    out=malloc(bytes);if(!out||JxlDecoderSetImageOutBuffer(d,&fmt,out,bytes)!=JXL_DEC_SUCCESS)break;
   } else if(s==JXL_DEC_FULL_IMAGE) {continue;}
   else if(s==JXL_DEC_SUCCESS) {if(out)result=write_file(argv[3],out,bytes);break;}
   else break;
  }
 dec_end:free(out);JxlDecoderDestroy(d);
 } else if(!strcmp(argv[1],"encode")&&argc==8) {
  int w=atoi(argv[4]),h=atoi(argv[5]),ch=atoi(argv[6]),bits=atoi(argv[7]);
  if(w<1||w>1024||h<1||h>1024||ch<1||ch>4||(bits!=8&&bits!=16)||n!=(size_t)w*h*ch*(bits/8))goto end;
  JxlEncoder *e=JxlEncoderCreate(NULL);if(!e)goto end;
  unsigned char *out=malloc(8*1024*1024);if(!out){JxlEncoderDestroy(e);goto end;}
  JxlBasicInfo info;JxlEncoderInitBasicInfo(&info);info.xsize=w;info.ysize=h;info.bits_per_sample=bits;
  info.num_color_channels=ch<3?1:3;info.num_extra_channels=ch%2==0;info.alpha_bits=ch%2==0?bits:0;info.uses_original_profile=JXL_FALSE;
  JxlColorEncoding col;JxlColorEncodingSetToSRGB(&col,ch<3);
  if(JxlEncoderSetBasicInfo(e,&info)!=JXL_ENC_SUCCESS||JxlEncoderSetColorEncoding(e,&col)!=JXL_ENC_SUCCESS)goto enc_end;
  JxlEncoderFrameSettings *fs=JxlEncoderFrameSettingsCreate(e,NULL);
  if(!fs||JxlEncoderSetFrameDistance(fs,1)!=JXL_ENC_SUCCESS||JxlEncoderFrameSettingsSetOption(fs,JXL_ENC_FRAME_SETTING_EFFORT,3)!=JXL_ENC_SUCCESS)goto enc_end;
  JxlPixelFormat fmt={(uint32_t)ch,bits==8?JXL_TYPE_UINT8:JXL_TYPE_UINT16,JXL_LITTLE_ENDIAN,0};
  if(JxlEncoderAddImageFrame(fs,&fmt,in,n)!=JXL_ENC_SUCCESS)goto enc_end;
  JxlEncoderCloseInput(e);unsigned char *next=out;size_t avail=8*1024*1024;
  if(JxlEncoderProcessOutput(e,&next,&avail)==JXL_ENC_SUCCESS)result=write_file(argv[3],out,(size_t)(next-out));
 enc_end:free(out);JxlEncoderDestroy(e);
 }
end:free(in);return result;
}
