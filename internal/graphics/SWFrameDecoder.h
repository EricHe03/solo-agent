#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class SWAccessUnit;

@interface SWFrameDecoder : NSObject
@property (nonatomic, copy) void (^onFrame)(CVPixelBufferRef image, SWAccessUnit *unit);

- (void)invalidate;
- (BOOL)decode:(SWAccessUnit *)unit;
@end
