#import <Foundation/Foundation.h>

@class SWRaster;

@interface SWPlane : NSObject
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) float *values NS_RETURNS_INNER_POINTER;

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height;
- (instancetype)initWithRaster:(SWRaster *)raster error:(NSError **)error;
- (SWPlane *)scaledToWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error;
- (SWPlane *)squares;
@end

@interface SWKernel : NSObject
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) SWPlane *centered;
@property (nonatomic, readonly) SWPlane *weights;
@property (nonatomic, readonly) float weightSum;
@property (nonatomic, readonly) float variance;

- (instancetype)initWithValues:(SWPlane *)values weights:(SWPlane *)weights error:(NSError **)error;
@end

@interface SWColorKernel : NSObject
- (instancetype)initWithTemplate:(SWRaster *)template alpha:(SWPlane *)alpha error:(NSError **)error;
- (float)scoreIn:(SWRaster *)target x:(NSInteger)x y:(NSInteger)y;
@end

SWPlane *SWTemplateWeights(SWRaster *template, NSError **error);
