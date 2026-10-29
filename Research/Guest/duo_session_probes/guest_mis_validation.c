#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
extern int MISValidateSignatureAndCopyInfoWithProgress(CFStringRef,CFDictionaryRef,CFDictionaryRef *,void *);
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 void *h=dlopen("/usr/lib/libmisfix.dylib",RTLD_NOW|RTLD_GLOBAL);
 if(!h){fprintf(stderr,"%s\n",dlerror());return 3;}
 CFStringRef path=CFStringCreateWithCString(NULL,argv[1],kCFStringEncodingUTF8);
 for(int i=0;i<64;i++) {
  CFDictionaryRef info=NULL;
  int status=MISValidateSignatureAndCopyInfoWithProgress(path,NULL,&info,NULL);
  if(status){fprintf(stderr,"validation failed 0x%x\n",status);return 4;}
  if(info)CFRelease(info);
 }
 CFRelease(path);
 puts("PASS: 64 real MIS signature validations with repaired native-X1 detour");
 return 0;
}
