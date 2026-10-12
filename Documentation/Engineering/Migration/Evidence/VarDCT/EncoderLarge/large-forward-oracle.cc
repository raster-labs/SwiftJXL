// Test-only direct pinned libjxl forward transform and LLF/DC extraction.
#include <cstdio>
#include <tuple>
#include <initializer_list>
#include "lib/jxl/enc_transforms-inl.h"
int main(int argc,char**argv){if(argc!=2)return 1;FILE*f=fopen(argv[1],"wb");if(!f)return 1;
for(auto [id,rows,cols]:{std::tuple<int,int,int>{4,16,16},{5,32,32},{6,16,8},{7,8,16},{8,32,8},{9,8,32},{10,32,16},{11,16,32},{18,64,64},{19,64,32},{20,32,64}}){
 for(int pattern=0;pattern<4;pattern++){
 alignas(64) float pixels[4096]={},coef[4096]={},dc[64]={},scratch[16384]={};
 for(int y=0;y<rows;y++)for(int x=0;x<cols;x++)pixels[y*cols+x]=pattern==0?.375f:pattern==1?(x==0&&y==0?1.f:0.f):pattern==2?(x==cols/2&&y==rows/2?1.f:0.f):float((x*17+y*11)%29-14)/31;
 auto strategy=static_cast<jxl::AcStrategyType>(id);
 jxl::HWY_NAMESPACE::TransformFromPixels(strategy,pixels,cols,coef,scratch);
 jxl::HWY_NAMESPACE::DCFromLowestFrequencies(strategy,coef,dc,cols/8,scratch);
 if(fwrite(coef,4,rows*cols,f)!=size_t(rows*cols)||fwrite(dc,4,rows*cols/64,f)!=size_t(rows*cols/64))return 2;
 }}return fclose(f);}
