/*
 * Created 181120  lynnl
 */

#import <Foundation/Foundation.h>

#define CheckNotNull(ex)        NSParameterAssert(ex != nil)
#define CheckArgument(ex)       NSParameterAssert(ex)
/* Roughly same as CheckArgument  yet do NOT misuse with them */
#define CheckStatus(ex)         NSParameterAssert(ex)

/* Pure C variant assertions */
#define CCheckNotNull(ex)       NSCParameterAssert(ex != nil)
#define CCheckArgument(ex)      NSCParameterAssert(ex)
#define CCheckStatus(ex)        NSCParameterAssert(ex)   /* ditto. */

#define LOG_OFF(fmt, ...)       (void) ((void) 0, ##__VA_ARGS__)
#ifdef DEBUG
#define LOG_DBG(fmt, ...)       NSLog(@"[DBG] " fmt, ##__VA_ARGS__)
#else
#define LOG_DBG(fmt, ...)       LOG_OFF(fmt, ##__VA_ARGS__)
#endif
#define LOG_INF(fmt, ...)       NSLog(@"[INF] " fmt, ##__VA_ARGS__)
#define LOG_WAR(fmt, ...)       NSLog(@"[WAR] " fmt, ##__VA_ARGS__)
#define LOG_ERR(fmt, ...)       NSLog(@"[ERR] " fmt, ##__VA_ARGS__)

/* XXX: ONLY quote those deprecated functions */
#define SUPPRESS_WARN_DEPRECATED_DECL_BEGIN     \
    _Pragma("clang diagnostic push")            \
    _Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"")

#define SUPPRESS_WARN_DEPRECATED_DECL_END       \
    _Pragma("clang diagnostic pop")

/*
 * Should only used for char[](NOT char *)
 */
#define QSTRLEN(s) (sizeof(s) - 1)

@interface LibUtils : NSObject

+ (void)mdelay:(long)ms;

@end

