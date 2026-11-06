#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class SWCancelToken;
@class SWRaster;

@interface SWMatch : NSObject
@property (nonatomic, readonly) CGRect rect;
@property (nonatomic, readonly) double score;
@property (nonatomic, readonly) double scale;
@end

NSArray<SWMatch *> *SWTemplateMatchingFind(SWRaster *target, SWRaster *template, NSArray<NSNumber *> *factors, double threshold, NSInteger limit, double overlap, SWCancelToken *token, NSError **error);
