#include <hwy/targets.h>
extern "C" int oracle_main(int,char**);
int main(int argc,char**argv) {hwy::SetSupportedTargetsForTest(HWY_SCALAR);return oracle_main(argc,argv);}
