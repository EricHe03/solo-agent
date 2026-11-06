#import <Foundation/Foundation.h>

@interface SWGoObject : NSObject
@property (nonatomic, readonly) uintptr_t handle;

- (instancetype)initWithHandle:(uintptr_t)handle;
@end

@interface SWTimelineWatch : SWGoObject
- (NSString *)stop;
@end

@interface SWCallContext : SWGoObject
@property (nonatomic, readonly) BOOL cancelled;
@property (nonatomic, readonly) BOOL tracing;

- (void)traceName:(NSString *)name detail:(NSString *)detail started:(double)started duration:(double)duration;
- (BOOL)authorize:(NSString *)path write:(BOOL)write error:(NSError **)error;
- (NSData *)screenshotWithScale:(double *)scale error:(NSError **)error;
- (SWTimelineWatch *)watchTimeline;
- (void)publish:(NSString *)value;
@end

@interface SWDeviceFeed : SWGoObject
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) double scale;

+ (instancetype)openWithError:(NSError **)error;
- (void)requestKeyFrame;
- (void)close;
@end

void SWLogError(NSString *message);
void SWReportRecordingFailure(NSString *message);
