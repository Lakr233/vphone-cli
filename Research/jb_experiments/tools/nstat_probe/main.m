#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <sys/utsname.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <stdarg.h>

// ntstat.h wire format, xnu-12377.121.6
// kern_control.h is not in the iOS SDK: declare the kernel-control socket API locally.
#define SYSPROTO_CONTROL 2
#define AF_SYS_CONTROL 2
struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; };
#define CTLIOCGINFO _IOWR('N', 3, struct ctl_info)
struct sockaddr_ctl { u_char sc_len; u_char sc_family; u_int16_t ss_sysaddr; u_int32_t sc_id; u_int32_t sc_unit; u_int32_t sc_reserved[5]; };
#include <sys/ioccom.h>
struct hdr { u_int64_t context; u_int32_t type; u_int16_t length; u_int16_t flags; };   // 16
struct add_all { struct hdr h; u_int64_t filter; u_int64_t events; u_int32_t provider; int32_t target_pid; u_int8_t target_uuid[16]; }; // 56
struct query { struct hdr h; u_int64_t srcref; };                                        // 24

static FILE *g_log;
static void L(const char *f, ...) { va_list a; char b[4096]; va_start(a,f); vsnprintf(b,sizeof b,f,a); va_end(a); NSLog(@"%s",b); if(g_log){ fputs(b,g_log); fputc('\n',g_log); fflush(g_log);} }
static const char *E(int e){ return strerror(e); }

static int drain(int fd, int ms, int *nmsg, u_int32_t *types, int tmax){
    struct timeval tv={0,ms*1000}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof tv);
    unsigned char buf[16384]; *nmsg=0; int bytes=0;
    for(;;){ ssize_t n=recv(fd,buf,sizeof buf,0); if(n<=0) break; bytes+=n;
        if(n>=16 && *nmsg<tmax){ types[*nmsg]=((struct hdr*)buf)->type; (*nmsg)++; }
        if(*nmsg<=2 && n>=16){ struct hdr*h=(struct hdr*)buf; L("  reply#%d: type=%u len=%u flags=%u bytes=%zd err=%u ctx=%llu",*nmsg,h->type,h->length,h->flags,n,(n>=20)?*(u_int32_t*)(buf+16):0,(unsigned long long)h->context);
            unsigned char *p=buf+16; char b[512]=""; for(int i=0;i<64&&i+16<n;i++) snprintf(b+strlen(b),sizeof b-strlen(b),"%02x",p[i]); L("  payload[0..48]: %s",b); }
    }
    return bytes;
}
static int run(int provider,int *sent,int *got,int *bytes,u_int32_t *types){
    struct ctl_info ci; memset(&ci,0,sizeof ci); strcpy(ci.ctl_name,"com.apple.network.statistics");
    int fd=socket(PF_SYSTEM,SOCK_DGRAM,SYSPROTO_CONTROL); if(fd<0){ L("socket -> -1 %s",E(errno)); return -1; }
    int r=ioctl(fd,CTLIOCGINFO,&ci); L("CTLIOCGINFO -> %d id=%u %s",r,ci.ctl_id,r?E(errno):"");
    if(r) { close(fd); return -1; }
    struct sockaddr_ctl sc; memset(&sc,0,sizeof sc); sc.sc_len=sizeof sc; sc.sc_family=AF_SYSTEM; sc.ss_sysaddr=AF_SYS_CONTROL; sc.sc_id=ci.ctl_id; sc.sc_unit=0;
    r=connect(fd,(struct sockaddr*)&sc,sc.sc_len); L("connect -> %d %s",r,r?E(errno):"");
    if(r){ close(fd); return -1; }
    struct add_all a; memset(&a,0,sizeof a); a.h.type=1002; a.h.length=sizeof a; a.provider=provider;
    ssize_t n=send(fd,&a,sizeof a,0); L("ADD_ALL(provider=%d) -> %zd %s",provider,n,n<0?E(errno):"");
    *sent=1; sleep(1);
    struct query q; memset(&q,0,sizeof q); q.h.type=1004; q.h.length=sizeof q; q.srcref=~0ULL;
    n=send(fd,&q,sizeof q,0); L("QUERY_SRC(ALL) -> %zd %s",n,n<0?E(errno):"");
    *bytes=drain(fd,800,got,types,64); L("  drained %d bytes, %d msgs",*bytes,*got);
    if(*got){ char t[512]=""; for(int i=0;i<*got&&i<64;i++) snprintf(t+strlen(t),sizeof t-strlen(t),"%u ",types[i]); L("  types: %s",t); }
    close(fd); return 0;
}
static void probe(void){
@autoreleasepool{
NSString *doc=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
g_log=fdopen(open([[doc stringByAppendingPathComponent:@"out.txt"] UTF8String],O_CREAT|O_WRONLY|O_TRUNC,0644),"w");
struct utsname u; uname(&u); L("iOS | %s",u.release);
int providers[]={0,1,2,3,4,5,6};
for(unsigned i=0;i<sizeof providers/sizeof*providers;i++){ int s,g=0,b=0; u_int32_t t[64]; L("== provider %d ==",providers[i]); run(providers[i],&s,&g,&b,t); }
L("done"); fclose(g_log);
}
}
@interface VC : UIViewController @end
@implementation VC @end
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window=[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController=[[VC alloc] init];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ probe(); });
    return YES;
}
@end
int main(int argc,char*argv[]){ @autoreleasepool { return UIApplicationMain(argc,argv,nil,@"AppDelegate"); } }
