// SPDX-License-Identifier: Apache-2.0
// Test-only direct invocation of the pinned independent AFV inverse.
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include "lib/jxl/dec_transforms-inl.h"
int main(int argc,char**argv){if(argc!=2)return 1;FILE*f=fopen(argv[1],"wb");if(!f)return 1;for(int kind : {1,2,3,12,13,14,15,16,17})for(int basis=0;basis<65;basis++){alignas(64) float c[64]={},p[64]={};for(int i=0;i<64;i++)c[i]=basis<64?(i==basis?1:0):float((i*17%29)-14)/31;alignas(64) float scratch[256]={};jxl::HWY_NAMESPACE::TransformToPixels(static_cast<jxl::AcStrategyType>(kind),c,p,8,scratch);if(fwrite(p,sizeof(float),64,f)!=64)return 1;}return fclose(f);}
