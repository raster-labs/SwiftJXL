#include <arm_neon.h>
#include <stdio.h>
#include <stdint.h>
int main(void){for(int q=0;q<=256;q++){float x=q;union{float f;uint32_t u;}v={.f=vgetq_lane_f32(vrecpeq_f32(vdupq_n_f32(x)),0)};printf("%s%u",q?",":"",v.u);}puts("");}
