#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@interface SWRaster : NSObject
@property (nonatomic, readonly) uint8_t *data NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger rowBytes;
@property (nonatomic, readonly) NSInteger channels;
@property (nonatomic, readonly) BOOL isGray;
@property (nonatomic, readonly) vImage_Buffer buffer;

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height channels:(NSInteger)channels;
- (instancetype)initAdoptingBytes:(void *)bytes width:(NSInteger)width height:(NSInteger)height rowBytes:(NSInteger)rowBytes;
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer width:(NSInteger)width height:(NSInteger)height error:(NSError **)error;
- (SWRaster *)viewOfRect:(CGRect)pixels;
- (void)readPixelAtX:(NSInteger)x y:(NSInteger)y into:(NSInteger[4])pixel;
- (void)copyInto:(SWRaster *)destination x:(NSInteger)x y:(NSInteger)y;
- (void)copyFloatsInto:(float *)values;
@end

BOOL SWRequire(vImage_Error status, NSString *operation, NSError **error);

SWRaster *SWRasterDecode(NSData *data, NSError **error);
SWRaster *SWRasterFromImage(CGImageRef image, NSError **error);
CGImageRef SWRasterCreateImage(SWRaster *raster, NSError **error) CF_RETURNS_RETAINED;
NSData *SWRasterEncode(SWRaster *raster, NSString *format, NSNumber *quality, double scale, NSError **error);

SWRaster *SWRasterResized(SWRaster *raster, NSInteger width, NSInteger height, NSError **error);
SWRaster *SWRasterRotatedQuarters(SWRaster *raster, NSInteger quarterTurns, NSError **error);
SWRaster *SWRasterRotatedDegrees(SWRaster *raster, double degrees, NSInteger width, NSInteger height, NSError **error);

SWRaster *SWRasterGrayscale(SWRaster *raster, NSError **error);
SWRaster *SWRasterLookUp(SWRaster *raster, const uint8_t table[256], NSError **error);
SWRaster *SWRasterThresholded(SWRaster *raster, NSInteger level, NSError **error);
SWRaster *SWRasterMasked(SWRaster *raster, const uint8_t low[3], const uint8_t high[3], NSError **error);
SWRaster *SWRasterInverted(SWRaster *raster, NSError **error);
SWRaster *SWRasterMorphed(SWRaster *raster, NSInteger radius, BOOL dilate, NSError **error);

NSArray<SWRaster *> *SWRasterPlanes(SWRaster *raster, NSError **error);
NSDictionary<NSString *, NSArray<NSNumber *> *> *SWRasterStatistics(SWRaster *raster, NSError **error);
