/*
 * Created 181119  lynnl
 */

#import "FSEventStream.h"
#import "LibUtils.h"


#include <sys/stat.h>
#include <sys/mount.h>

@interface FSEventStream ()

@property (nonatomic, strong) NSString *path;
/*
 * Simplified checkpoint(backing type is a POSIX style time_t)
 */
@property (nonatomic, assign) SInt64 checkpoint;

@property (nonatomic, assign) dev_t devno;
@property (nonatomic, strong) NSString *devMountAt;
/* ends with '/' */
@property (nonatomic, strong) NSData *devMountPrefix;
@property (nonatomic, assign) FSEventStreamEventId sinceWhen;

@property (nonatomic, assign) FSEventStreamRef historyStreamRef;
@property (nonatomic, assign) FSEventStreamRef realtimeStreamRef;

@property (nonatomic, assign) BOOL historyDone;
@property (nonatomic, strong) NSMutableDictionary *historyEventsMap;
@property (nonatomic, strong) NSMutableArray *pendingRealtimeEvents;

@end

@implementation FSEventStream

/**
 * @checkpoint  0 indicates events from beginning of the time(unlikely)
 *              -1 indicates no checkpoint at all
 *              time format in seconds(i.e. POSIX style time_t)
 */
- (nonnull instancetype)init:(NSString *)path checkpoint:(SInt64)checkpoint {
    CheckNotNull(path);
    if (checkpoint < -1) {
        LOG_WAR("negative checkpoint timestamp %lld  fallback to -1(no checkpoint)", checkpoint);
        checkpoint = -1;
    }

    self = [super init];
    CheckNotNull(self);
    self.path = path;
    self.checkpoint = checkpoint;

    time_t now = time(NULL);
    if (checkpoint >= now) {
        LOG_WAR("checkpoint timestamp exceeds now  %lld vs %ld", checkpoint, now);
    } else if (checkpoint == 0) {
        LOG_WAR("checkpoint timestamp is beginning of the time");
    }

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"[%@ path: %@ cp: %lld dev: %#x mnt: %@ eid: %#llx hi: %p(%d) rt: %p]",
            self.className, self.path, self.checkpoint, self.devno, self.devMountAt, self.sinceWhen,
            self.historyStreamRef, self.historyDone, self.realtimeStreamRef];
}

- (BOOL)prepareDevice {
    CheckStatus(self.devno == 0);   /* Call only once */

    const char *cpath = [self.path UTF8String];
    CheckNotNull(cpath);
    struct stat st;
    struct statfs stfs;

    if (lstat(cpath, &st) != 0) {
        LOG_ERR("lstat(2) failure  path: %@ errno: %d", self.path, errno);
        return NO;
    }

    if (statfs(cpath, &stfs) != 0) {
        LOG_ERR("statfs(2) failure  path: %@ errno: %d", self.path, errno);
        return NO;
    }

    if (st.st_dev != stfs.f_fsid.val[0]) {
        LOG_ERR("TOUTTOC bug  st.st_dev: %#x stfs.f_fsid.val[0]: %#x",
                    st.st_dev, stfs.f_fsid.val[0]);
        return NO;
    }

    LOG_DBG("stfs.f_fsid: {%#x, %#x}", stfs.f_fsid.val[0], stfs.f_fsid.val[1]);

    NSString *mnt = [NSString stringWithUTF8String:stfs.f_mntonname];
    if (![self.path hasPrefix:mnt]) {
        LOG_ERR("target path %@ not starts with mountpoint %@", self.path, mnt);
        return NO;
    }

    NSMutableData *data = [NSMutableData dataWithData:[mnt dataUsingEncoding:NSUTF8StringEncoding]];
    if (![mnt hasSuffix:@"/"]) [data appendBytes:"/" length:1];

    self.devno = st.st_dev;
    self.devMountAt = mnt;
    self.devMountPrefix = [NSData dataWithData:data];

    LOG_INF("device prepared  path: %@ dev: %#x(%d:%d) mnt: %@",
        self.path, self.devno, major(st.st_dev), minor(st.st_dev), self.devMountAt);

    return YES;
}

#define PRT_EVTS_BUFSZ  1024

- (BOOL)prepareCheckpoint {
    CheckStatus(self.devno != 0);   /* Call [self prepareCheckpoint] first */

    if (self.checkpoint == -1) {
        self.sinceWhen = kFSEventStreamEventIdSinceNow;
        LOG_INF("skip :. no checkpoint provided");
        return YES;
    }

    CFUUIDRef uuid = FSEventsCopyUUIDForDevice(self.devno);
    if (uuid == NULL) {
        LOG_ERR("FSEventsCopyUUIDForDevice() failure");
        return NO;
    }
    CFStringRef uuidStr = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    if (uuidStr == NULL) {
        LOG_ERR("CFUUIDCreateString() failure");
        CFRelease(uuid);
        return NO;
    }
    LOG_INF("device %#x  UUID: %@", self.devno, uuidStr);

    /*
     * Q: will the event id be zero?
     * A: it's possible when if no event by given time
     */
    FSEventStreamEventId eid =
        FSEventsGetLastEventIdForDeviceBeforeTime(self.devno, (CFAbsoluteTime) self.checkpoint);

    self.sinceWhen = eid;
    self.historyEventsMap = [NSMutableDictionary dictionary];
    self.pendingRealtimeEvents = [NSMutableArray arrayWithCapacity:PRT_EVTS_BUFSZ];

    LOG_INF("checkpoint prepared  ts: %lld eid: %#llx", self.checkpoint, eid);

    CFRelease(uuid);
    CFRelease(uuidStr);

    return YES;
}

- (BOOL)needsHistoryEvents {
    return self.sinceWhen > 0 && self.sinceWhen != kFSEventStreamEventIdSinceNow;
}

- (BOOL)createFSEventStream:(dispatch_queue_t)queue isHistory:(BOOL)isHistory {
    /* relpath won't begin with path separator :. self.devMountAt ends with it */
    NSString *relpath = [self.path substringFromIndex:self.devMountAt.length];
    NSArray *pathsToWatch = @[relpath];

    FSEventStreamEventId since;
    FSEventStreamCallback callback;
    CFAbsoluteTime latency = 0.0;
    FSEventStreamCreateFlags flags = 0;

    flags |= kFSEventStreamCreateFlagWatchRoot;
    flags |= kFSEventStreamCreateFlagNoDefer;
    /*
     * file-level events should both be set for history/realtime events
     *  o.w. in history replay  the event flags will very likely to be 0
     */
    flags |= kFSEventStreamCreateFlagFileEvents;

    if (isHistory) {
#if 0
        flags &= ~kFSEventStreamCreateFlagFileEvents;
#endif
        since = self.sinceWhen;
        callback = history_events_callback;
    } else {
        since = kFSEventStreamEventIdSinceNow;
        callback = realtime_events_callback;
    }

    struct FSEventStreamContext ctx = {
        .info = (__bridge void *) self,
    };

    FSEventStreamRef streamRef =
        FSEventStreamCreateRelativeToDevice(
            NULL, callback, &ctx, self.devno,
            (__bridge CFArrayRef) pathsToWatch, since, latency, flags);

    if (streamRef == NULL) {
        LOG_ERR("FSEventStreamCreateRelativeToDevice() failure  path: %@ history: %d",
                    self.path, isHistory);
        return NO;
    }

    if (isHistory) {
        self.historyStreamRef = streamRef;
    } else {
        self.realtimeStreamRef = streamRef;
    }

    FSEventStreamSetDispatchQueue(streamRef, queue);
    return FSEventStreamStart(streamRef);
}

- (BOOL)prepare:(dispatch_queue_t)queue {
    CheckNotNull(queue);

    LOG_INF("going to prepare device/checkpoint and start fsevents");

    if (![self prepareDevice] || ![self prepareCheckpoint]) return NO;

    /* Create real-time fsevent stream to avoid event lost */
    if (![self createFSEventStream:queue isHistory:NO]) return NO;

    if ([self needsHistoryEvents]) {
        if (![self createFSEventStream:queue isHistory:YES]) {
            dispatch_async(queue, ^{
                [self historyEventsEnded];
                [self stopRealtimeFSEventStream];
            });
            return NO;
        }

        /*
         * When history fsevent registered successfully
         *  the corresponding fsevent callback will call at least once
         *  otherwise history fsevent have no chance to end itself
         */
    } else {
        LOG_DBG("skip create history fsevents :. no checkpoint");
        dispatch_async(queue, ^{ [self historyEventsEnded]; });
    }

    return YES;
}

- (void)stopHistoryFSEventStream {
    if (self.historyStreamRef) {
        FSEventStreamStop(self.historyStreamRef);
        FSEventStreamInvalidate(self.historyStreamRef);
        FSEventStreamRelease(self.historyStreamRef);
        self.historyStreamRef = nil;

        LOG_DBG("history fsevents stopped");
    }
}

- (void)stopRealtimeFSEventStream {
    if (self.realtimeStreamRef) {
        FSEventStreamStop(self.realtimeStreamRef);
        FSEventStreamInvalidate(self.realtimeStreamRef);
        FSEventStreamRelease(self.realtimeStreamRef);
        self.realtimeStreamRef = nil;

        LOG_DBG("realtime fsevents stopped");
    }
}

- (void)stopFSEventStreams {
    [self stopHistoryFSEventStream];
    [self stopRealtimeFSEventStream];
}

- (void)addHistoryEvent:(NSString *)path eid:(FSEventStreamEventId)eid flags:(FSEventStreamEventFlags)flags {
    NSArray *old = [self.historyEventsMap valueForKey:path];
    NSArray *new = @[@(eid), @(flags)];
    if (old != nil) {
        NSString *s1 = [NSString stringWithFormat:@"{\n\t%#llx, %#x\n}",
            [[old objectAtIndex:0] unsignedLongLongValue], [[old objectAtIndex:1] unsignedIntValue]];
        NSString *s2 = [NSString stringWithFormat:@"{\n\t%#llx, %#x\n}",
            [[new objectAtIndex:0] unsignedLongLongValue], [[new objectAtIndex:1] unsignedIntValue]];
        LOG_DBG("history events map contains %@ -> %@  overwrite with %@",
                path, s1, s2);
    }
    /* TODO: we should use an array to store all history events :. the mapping isn't 1to1 */
    [self.historyEventsMap setObject:new forKey:path];
}

static const char hi_evts_beg_cmd[] = "history_fsevents\n";
/*
 * We can use a single linefeed as a generic command terminator  just as HTTP
 */
static const char hi_evts_end_cmd[] = "end\n";

- (void)historyEventsEnded {
    [self stopHistoryFSEventStream];

    long val = pathconf([self.path UTF8String], _PC_CASE_SENSITIVE);
    BOOL caseSensitive;
    if (val == -1) LOG_ERR("pathconf(2) failure  path: %@ errno: %d", self.path, errno);
    caseSensitive = val > 0;

    NSArray *origin = [self.historyEventsMap allKeys];
    NSArray *sorted = [origin sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *x = (NSString *) a;
        NSString *y = (NSString *) b;
        return [x compare:y options:caseSensitive ? 0 : NSCaseInsensitiveSearch];
    }];

    NSMutableData *data = [NSMutableData dataWithCapacity:8192];
    NSString *prevPath = nil;
    BOOL mustScanSubDirs = NO;

    /*
     * History fsevent data format
     *  history_fsevents
     *  %#llx %#x %c%c%c %s
     *  %#llx %#x %c%c%c %s
     *  ...
     *  end
     */
    [data appendBytes:hi_evts_beg_cmd length:QSTRLEN(hi_evts_beg_cmd)];
    for (NSString *path in sorted) {
        if (prevPath != nil && mustScanSubDirs) {
            if ([LibUtils isAncestorOf:prevPath descendant:path caseSensitive:caseSensitive]) {
                LOG_DBG("skip %@ as it'll be scanned by its ancestor", path);
                continue;
            }
        }

        NSArray *arr = [self.historyEventsMap objectForKey:path];
        CheckNotNull(arr);
        CheckStatus(arr.count == 2);

        FSEventStreamEventId eid = [[arr objectAtIndex:0] unsignedLongLongValue];
        FSEventStreamEventFlags flags = [[arr objectAtIndex:1] unsignedIntValue];
        BOOL isDir = !!(flags & kFSEventStreamEventFlagItemIsDir);
        BOOL isFile = !!(flags & kFSEventStreamEventFlagItemIsFile);
        BOOL rootChanged = !!(flags & kFSEventStreamEventFlagRootChanged);
        mustScanSubDirs = isDir && !!(flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemRenamed));
        BOOL shouldIgnore = !(isDir || isFile || rootChanged || mustScanSubDirs);
        if (shouldIgnore) {
            LOG_WAR("hi event %#llx ignored  path: %@ flags: %#x", eid, path, flags);
            continue;
        }

        NSData *eidData = [[NSString stringWithFormat:@"%#llx", eid] dataUsingEncoding:NSUTF8StringEncoding];
        [data appendData:eidData];
        [data appendBytes:" " length:1];

        NSData *flagsData = [[NSString stringWithFormat:@"%#x", flags] dataUsingEncoding:NSUTF8StringEncoding];
        [data appendData:flagsData];
        [data appendBytes:" " length:1];

        [data appendBytes:(isDir ? "D" : "F") length:1];
        [data appendBytes:(mustScanSubDirs ? "R" : "-") length:1];
        [data appendBytes:(rootChanged ? "P" : "-") length:1];
        [data appendBytes:" " length:1];

        [data appendData:self.devMountPrefix];
        [data appendData:[path dataUsingEncoding:NSUTF8StringEncoding]];
        [data appendBytes:"\n" length:1];

        prevPath = path;
    }
    [data appendBytes:hi_evts_end_cmd length:QSTRLEN(hi_evts_end_cmd)];

    /*
     * The wrapped data not null-terminated  .: use [NSString initWithData]
     * see: https://stackoverflow.com/a/2467856
     */
    LOG_INF("%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);

    if (self.pendingRealtimeEvents.count != 0) LOG_DBG("push pending rt events");
    for (NSData *data in self.pendingRealtimeEvents) {
        LOG_INF("%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    }

    self.pendingRealtimeEvents = nil;
    self.historyEventsMap = nil;
    self.historyDone = YES;

    LOG_DBG("%@", self);
    LOG_INF("hi events ended");
}

static void history_events_callback(
        ConstFSEventStreamRef streamRef,
        void * __nullable clientCallBackInfo,
        size_t numEvents,
        void *eventPaths,
        const FSEventStreamEventFlags  * _Nonnull eventFlags,
        const FSEventStreamEventId * _Nonnull eventIds)
{
    const char **paths = (typeof(paths)) eventPaths;
    FSEventStream *stream = (__bridge typeof(stream)) clientCallBackInfo;
    NSString *p;
    size_t i;

    LOG_DBG("<< history events begins");
    for (i = 0; i < numEvents; i++) {
        if (eventFlags[i] & kFSEventStreamEventFlagHistoryDone) {
            LOG_DBG(">> history events ended  %zu of %zu", i, numEvents);
            [stream historyEventsEnded];
            break;
        }

        p = [NSString stringWithUTF8String:paths[i]];
        LOG_DBG("hi event  eid: %#llx flags: %#x path: %@",
                    eventIds[i], eventFlags[i], p);

        [stream addHistoryEvent:p eid:eventIds[i] flags:eventFlags[i]];

        [LibUtils mdelay:10];  /* Prevent from call too soon  TODO: use latency */
    }
}

static const char rt_evts_beg_cmd[] = "realtime_fsevents\n";
static const char rt_evts_end_cmd[] = "end\n";

static BOOL pack_rt_fsevent_data(
        NSMutableData *output,
        NSData *mntPrefix,
        FSEventStreamEventId eid,
        FSEventStreamEventFlags flags,
        const char *path)
{
    CCheckNotNull(output);
    CCheckNotNull(mntPrefix);
    CCheckNotNull(path);

    BOOL isDir = !!(flags & kFSEventStreamEventFlagItemIsDir);
    BOOL isFile = !!(flags & kFSEventStreamEventFlagItemIsFile);
    BOOL rootChanged = !!(flags & kFSEventStreamEventFlagRootChanged);
    BOOL mustScanSubDirs = isDir && !!(flags & (kFSEventStreamEventFlagMustScanSubDirs| kFSEventStreamEventFlagItemRenamed));
    BOOL shouldIgnore = !(isDir || isFile || rootChanged || mustScanSubDirs);
    if (shouldIgnore) {
        LOG_WAR("rt event %#llx ignored  path: %s flags: %#x", eid, path, flags);
        return NO;
    }

    /*
     * Realtime fsevent data format
     *  realtime_fsevents
     *  %#llx %#x %c%c%c %s
     *  %#llx %#x %c%c%c %s
     *  ...
     *  end
     */
    NSData *eidData = [[NSString stringWithFormat:@"%#llx", eid] dataUsingEncoding:NSUTF8StringEncoding];
    [output appendData:eidData];
    [output appendBytes:" " length:1];

    NSData *flagsData = [[NSString stringWithFormat:@"%#x", flags] dataUsingEncoding:NSUTF8StringEncoding];
    [output appendData:flagsData];
    [output appendBytes:" " length:1];

    [output appendBytes:(isDir ? "D" : "F") length:1];
    [output appendBytes:(mustScanSubDirs ? "R" : "-") length:1];
    [output appendBytes:(rootChanged ? "P" : "-") length:1];
    [output appendBytes:" " length:1];

    [output appendData:mntPrefix];
    [output appendBytes:path length:strlen(path)];
    [output appendBytes:"\n" length:1];

    return YES;
}

- (void)addRealtimeEvent:(NSData *)data {
    CheckNotNull(data);

    if (self.historyDone) {
        LOG_INF("%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    } else {
        /* Data from previously packed by pack_rt_fsevent_data() */
        [self.pendingRealtimeEvents addObject:data];
    }
}

#define RT_COLLAPSE_WSZ  10

static void realtime_events_callback(
        ConstFSEventStreamRef streamRef,
        void * __nullable clientCallBackInfo,
        size_t numEvents,
        void *eventPaths,
        const FSEventStreamEventFlags  * _Nonnull eventFlags,
        const FSEventStreamEventId * _Nonnull eventIds)
{
    const char **paths = (typeof(paths)) eventPaths;
    FSEventStream *stream = (__bridge typeof(stream)) clientCallBackInfo;
    size_t i;
    NSMutableData *data = nil;

    /* Realtime fsevents will be collapsed for every 10 contiguous events */
    for (i = 0; i < numEvents; i++) {
        if (i % RT_COLLAPSE_WSZ == 0) {
            data = [NSMutableData dataWithCapacity:4096];
            CCheckNotNull(data);
            [data appendBytes:rt_evts_beg_cmd length:QSTRLEN(rt_evts_beg_cmd)];
        }

        if (!pack_rt_fsevent_data(data, stream.devMountPrefix, eventIds[i], eventFlags[i], paths[i]))
            continue;

        if (i % RT_COLLAPSE_WSZ == RT_COLLAPSE_WSZ-1) {
            [data appendBytes:rt_evts_end_cmd length:QSTRLEN(rt_evts_end_cmd)];
            [stream addRealtimeEvent:data];
        }

        [LibUtils mdelay:50];
    }

    if (i % RT_COLLAPSE_WSZ != 0) {
        [data appendBytes:rt_evts_end_cmd length:QSTRLEN(rt_evts_end_cmd)];
        [stream addRealtimeEvent:data];
    }
}

@end

