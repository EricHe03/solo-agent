#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@class SWRaster;

typedef struct {
    NSInteger width;
    NSInteger height;
    double scale;
} SWScreenGeometry;

@interface SWFrame : NSObject
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly) NSInteger turns;
@property (nonatomic, readonly) SWScreenGeometry geometry;
@property (nonatomic, readonly) NSInteger pixelWidth;
@property (nonatomic, readonly) NSInteger pixelHeight;

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer time:(double)time turns:(NSInteger)turns geometry:(SWScreenGeometry)geometry;
- (SWRaster *)raster:(NSError **)error;
- (SWRaster *)quarter:(NSError **)error;
@end
