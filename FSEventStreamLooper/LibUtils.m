/*
 * Created 181121  lynnl
 */

#import <Foundation/Foundation.h>

#import "LibUtils.h"

#include <sys/_select.h>

@implementation LibUtils

+ (void)mdelay:(long)ms {
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (typeof(tv.tv_usec)) ((ms - tv.tv_sec * 1000) * 1000);
    if (select(0, NULL, NULL, NULL, &tv)) {
        NSLog(@"select() failure  errno: %d", errno);
    }
}

@end
