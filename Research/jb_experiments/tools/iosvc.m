#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
static void L(NSString *s){ printf("%s\n", s.UTF8String); }
static void probe(NSString *name){
    CFMutableDictionaryRef m = IOServiceMatching(name.UTF8String);
    if(!m){ L([NSString stringWithFormat:@"SVC %@ matching=NULL", name]); return; }
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m); // consumes m
    if(!s){ L([NSString stringWithFormat:@"SVC %@ inst=0", name]); return; }
    // count siblings by class
    io_iterator_t it; int n=1;
    if(IORegistryEntryCreateIterator(s,kIOServicePlane,kIORegistryIterateRecursively,&it)==KERN_SUCCESS){
        io_object_t o; while((o=IOIteratorNext(it))){ n++; IOObjectRelease(o);} IOObjectRelease(it);}    
    for(int t=0;t<3;t++){
        io_connect_t c=0; kern_return_t r=IOServiceOpen(s,mach_task_self(),t,&c);
        L([NSString stringWithFormat:@"SVC %@ inst=%d type=%d kr=0x%08x", name,n,t,r]);
        if(r==KERN_SUCCESS) IOServiceClose(c);
    }
    IOObjectRelease(s);
}
int main(){ @autoreleasepool{
    NSArray *names=@[@"AppleAVE2Driver",@"AppleAVE2",@"AppleAVD",@"AppleJPEGDriver",@"IOMobileFramebuffer",@"IOSurfaceRoot",@"AGXAccelerator",@"AppleH16ANE",@"IOGPUFamily",@"AppleStockholmControl",@"AppleSPU",@"AppleConvergedPCI",@"AppleBMW",@"AppleBiometricSensor",@"AppleBaseband",@"AppleMesa",@"AppleDocket",@"AppleFDR",@"AppleKeyStore",@"AppleARP",@"AppleJPEG",@"AppleSEP",@"AppleTorch",@"AppleH2CamIn",@"AppleH2CamOut"];
    for(NSString*n in names) probe(n);
    L(@"DONE"); } return 0; }
