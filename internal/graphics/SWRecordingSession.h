#import <Foundation/Foundation.h>

@class SWCancelToken;
@class SWTimelineWatch;
@class SWVideoModel;

@interface SWRecordingSession : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) double start;

+ (instancetype)startWithURL:(NSURL *)url timeline:(SWTimelineWatch *)timeline token:(SWCancelToken *)token error:(NSError **)error;
- (SWVideoModel *)stop:(SWCancelToken *)token error:(NSError **)error;
- (void)abandon;
@end
