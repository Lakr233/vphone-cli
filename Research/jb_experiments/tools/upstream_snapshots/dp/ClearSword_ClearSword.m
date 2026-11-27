//
//  ClearSword.m
//  Dopamine
//
//  Created by Lars Fröder on 30.07.26.
//

#import "exploit/poc.h"
#import "exploit/common.h"
#import "exploit/krw.h"
#import <libjailbreak/info.h>
#import <libjailbreak/primitives_external.h>

int exploit_init(const char *flavor)
{
    int r = clearsword_run();
    if (r != 0) return r;
    
    gPrimitives.kreadbuf = clearsword_kreadbuf;
    gPrimitives.kwritebuf = clearsword_kwritebuf;
    
    gSystemInfo.kernelConstant.slide = g_ctx.kernel_slide;
    gPrimitives.krwMinSafeReadSize = 0x20;
    
    return 0;
}

int exploit_deinit(void)
{
    return 0;
}
