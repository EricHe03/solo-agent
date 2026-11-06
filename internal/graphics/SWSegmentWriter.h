#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@class SWAccessUnit;

@interface SWSegmentWriter : NSObject
@property (nonatomic, readonly) CMVideoFormatDescriptionRef format;
@property (nonatomic, readonly) NSInteger turns;
@property (nonatomic, readonly) CMTime end;

- (instancetype)initWithURL:(NSURL *)url format:(CMVideoFormatDescriptionRef)format turns:(NSInteger)turns error:(NSError **)error;
- (CMTime)append:(SWAccessUnit *)unit;
- (void)finish:(void (^)(NSString *failure))done;
@end
