// Test-only direct invocation of pinned libjxl GaborishInverse.
#include <cstdio>
#include <utility>
#include "lib/jxl/enc_gaborish.h"
#include "lib/jxl/image.h"
int main(int argc,char**argv){
 if(argc!=2)return 1; FILE*f=fopen(argv[1],"wb");if(!f)return 2;
 JxlMemoryManager memory; if(!jxl::MemoryManagerInit(&memory,nullptr))return 6;
 for(auto dims:{std::pair<int,int>{1,1},{2,3},{7,5},{8,8},{17,9}}){
  int w=dims.first,h=dims.second;
  for(int pattern=0;pattern<3;pattern++){
   auto created=jxl::Image3F::Create(&memory,w,h);if(!created.ok())return 3;auto im=std::move(created).value_();
   for(int c=0;c<3;c++)for(int y=0;y<h;y++)for(int x=0;x<w;x++) im.Plane(c).Row(y)[x]=pattern==0?0.375f:pattern==1?(x==0&&y==0?1.f:0.f):float((x*17+y*11+c*7)%29-14)/31;
   float mul[3]={1,1,1};if(!jxl::GaborishInverse(&im,jxl::Rect(im),mul,nullptr))return 4;
   for(int c=0;c<3;c++)for(int y=0;y<h;y++)if(fwrite(im.Plane(c).Row(y),4,w,f)!=size_t(w))return 5;
  }
 }
 return fclose(f);
}
