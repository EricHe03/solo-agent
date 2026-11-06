#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class SWCancelToken;
@class SWImageNode;
@class SWRaster;

@interface SWScreenComparison : NSObject
- (instancetype)initWithNode:(SWImageNode *)node region:(const CGRect *)region threshold:(NSInteger)threshold error:(NSError **)error;
- (SWRaster *)plane:(SWImageNode *)node token:(SWCancelToken *)token error:(NSError **)error;
- (BOOL)changed:(SWRaster *)first from:(SWRaster *)second result:(BOOL *)result error:(NSError **)error;
@end
