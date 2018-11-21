/*
 * Created 181119  lynnl
 */

#import <Foundation/Foundation.h>
#import "FSEventStream.h"
#import "LibUtils.h"

#include <libgen.h>
#include <unistd.h>
#include <sys/_select.h>

static __dead2 void usage(int argc, char **argv)
{
    fprintf(stderr, "usage:\n\t%s [-c checkpoint] path\n\n", basename(argv[0]));
    exit(1);
}

#define LOG(fmt, ...)   NSLog(@"(main) " fmt, ##__VA_ARGS__)

int main(int argc, char *argv[])
{
    NSString *path;
    SInt64 cp = -1;
    char *endp;
    int c;

    while ((c = getopt(argc, argv, "c:")) != -1) {
        switch (c) {
        case 'c':
            /*
             * TODO: support human reable timestamp formats
             *  - -xx[s|m|h|d|y]  [[(%y|%Y)/]%m/%d][[%H]:%M[:%S]]
             */
            cp = strtoll(optarg, &endp, 10);
            if (*endp != '\0') {
                fprintf(stderr, "unrecognized checkpoint timestamp `%s'\n\n", optarg);
                exit(1);
            }
            break;
        case '?':
        default:
            usage(argc, argv);
        }
    }

    /* non-option argument path */
    if (optind != argc-1) {
        fprintf(stderr, "path is missing or invalid\n");
        usage(argc, argv);
    }
    path = @(argv[optind]);

    dispatch_queue_t q = dispatch_queue_create("fsevents_q", NULL);
    if (q == NULL) {
        LOG(@"dispatch_queue_create() failure");
        exit(1);
    }

    FSEventStream *ref = [[FSEventStream alloc] init:path checkpoint:cp];
    if (![ref prepare:q]) exit(1);
    LOG("%@", ref);

    /* sleep forever */
    [LibUtils mdelay:UINT_MAX];
    [ref stopFSEventStreams];

    return 0;
}

