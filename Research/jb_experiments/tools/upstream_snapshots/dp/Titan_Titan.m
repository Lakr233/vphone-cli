//
//  Titan.m
//  Dopamine
//
//  Created by alfie on 31/07/2026.
//

#import <Foundation/Foundation.h>
#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/primitives_IOSurface.h>

#include "exploit/titan.h"

int exploit_init(const char *flavor)
{
    if (titan_init() != 0) {
        return -1;
    }
    
    if (titan_run() != 0) {
        printf("ERROR: failed to run Titan\n");
        return -1;
    }

    gPrimitives.physwritebuf = titan_physwritebuf;
    
    return 0;
}

int exploit_deinit(void)
{
    titan_deinit();
    return 0;
}
