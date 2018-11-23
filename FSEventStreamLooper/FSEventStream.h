/*
 * Created 181119  lynnl
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FSEventStream : NSObject

@property (nonatomic, readonly, strong) NSString *path;
@property (nonatomic, readonly, assign) SInt64 checkpoint;

@property (nonatomic, readonly, assign) dev_t devno;
@property (nonatomic, readonly, strong) NSString *devMountAt;
@property (nonatomic, readonly, assign) FSEventStreamEventId sinceWhen;

- (nonnull instancetype)init:(nonnull NSString *)path checkpoint:(SInt64)checkpoint;

- (BOOL)prepare:(nonnull dispatch_queue_t)queue;

- (void)stopHistoryFSEventStream;
- (void)stopRealtimeFSEventStream;
- (void)stopFSEventStreams;

- (NSString *)description;

@end

NS_ASSUME_NONNULL_END

