/*
 * Created 181121  lynnl
 */

#import <Foundation/Foundation.h>

#import "LibUtils.h"

#include <sys/_select.h>

@implementation LibUtils

+ (void)mdelay:(long)ms {
    CheckArgument(ms >= 0);

    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (typeof(tv.tv_usec)) ((ms - tv.tv_sec * 1000) * 1000);
    if (select(0, NULL, NULL, NULL, &tv)) {
        NSLog(@"select() failure  errno: %d", errno);
    }
}

/**
 * Check if `descendant' a descendant of `ancestor'(assume they're normalized)
 * @ancestor    needle
 * @descendant  haystack
 * XXX: if ancestor and descendant equals  we'll return YES
 *
 * see: https://gist.github.com/boredzo/4325317
 */
+ (BOOL)isAncestorOf:(NSString *)an descendant:(NSString *)de caseSensitive:(BOOL)cs {
    static NSStringCompareOptions mask[]= {0, NSCaseInsensitiveSearch};

    CheckNotNull(an);
    CheckNotNull(de);

    return an.length <= de.length &&
        [de compare:an options:mask[!cs] range:NSMakeRange(0, an.length)] == NSOrderedSame &&
        (an.length == de.length || an.length == 1 || [de characterAtIndex:an.length] == '/');
}

@end
