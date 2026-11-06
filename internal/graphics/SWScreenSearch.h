#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class SWArguments;
@class SWCall;
@class SWCallContext;
@class SWCancelToken;
@class SWImageNode;

@interface SWScreenHit : NSObject
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) double score;
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSInteger target;
@end

@interface SWScreenSearch : NSObject
- (instancetype)initWithCall:(SWCall *)call firstObject:(NSUInteger)first error:(NSError **)error;
- (SWScreenHit *)check:(SWImageNode *)node error:(NSError **)error;
- (void)traceName:(NSString *)name started:(double)started hit:(SWScreenHit *)hit frameTime:(double)frameTime;
@end
