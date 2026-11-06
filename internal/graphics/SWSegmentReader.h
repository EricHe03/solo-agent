#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class SWCancelToken;

@interface SWDecodedBuffer : NSObject
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly) CVPixelBufferRef buffer NS_RETURNS_INNER_POINTER;
@end

typedef BOOL (^SWFrameVisitor)(double time, CVPixelBufferRef buffer, BOOL *going, NSError **error);

@interface SWSegmentReader : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (SWDecodedBuffer *)frameAt:(double)seconds error:(NSError **)error;
- (BOOL)eachFrom:(double)start through:(double)end token:(SWCancelToken *)token going:(BOOL *)going error:(NSError **)error visitor:(SWFrameVisitor)visitor;
@end
