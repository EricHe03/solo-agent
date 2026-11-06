#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class SWCancelToken;
@class SWFrame;
@class SWRaster;
@class SWVideoModel;

@interface SWImageNode : NSObject
@property (nonatomic, readonly) NSInteger pixelWidth;
@property (nonatomic, readonly) NSInteger pixelHeight;
@property (nonatomic, readonly) CGAffineTransform transform;
@property (nonatomic, readonly) BOOL gray;
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly) double timestamp;
@property (nonatomic, readonly) double scale;
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) SWFrame *screenFrame;
@property (nonatomic, readonly) NSInteger estimatedBytes;

+ (instancetype)nodeWithEncoded:(NSData *)data scale:(NSNumber *)scale timestamp:(double)timestamp error:(NSError **)error;
+ (instancetype)nodeWithFrame:(SWFrame *)frame;
+ (instancetype)nodeWithFrame:(SWFrame *)frame ofVideo:(SWVideoModel *)model;
+ (instancetype)nodeWithVideo:(SWVideoModel *)model time:(double)time;
+ (instancetype)nodeWithRaster:(SWRaster *)raster transform:(CGAffineTransform)transform;

- (BOOL)pixelRectInSpace:(CGRect)rect into:(CGRect *)pixels error:(NSError **)error;
- (CGPoint)pixelPointInSpace:(CGPoint)point;
- (NSArray<NSNumber *> *)spacePoint:(CGPoint)point;
- (CGRect)spaceRect:(CGRect)rect;

- (SWImageNode *)cropInSpace:(CGRect)rect error:(NSError **)error;
- (SWImageNode *)resizeToWidth:(NSInteger)width height:(NSInteger)height;
- (SWImageNode *)rotateDegrees:(double)degrees;
- (SWImageNode *)grayscaleNode;
- (SWImageNode *)thresholdNode:(NSInteger)level;
- (SWImageNode *)maskNodeLow:(const uint8_t[3])low high:(const uint8_t[3])high;
- (SWImageNode *)invertNode;
- (SWImageNode *)morphNode:(NSInteger)radius dilate:(BOOL)dilate;

- (SWRaster *)raster:(SWCancelToken *)token error:(NSError **)error;
- (SWRaster *)rasterInSpace:(const CGRect *)rect origin:(CGPoint *)origin token:(SWCancelToken *)token error:(NSError **)error;
@end
