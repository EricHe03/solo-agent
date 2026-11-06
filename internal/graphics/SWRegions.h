#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class SWCancelToken;
@class SWRaster;

typedef struct {
    NSInteger minX;
    NSInteger minY;
    NSInteger maxX;
    NSInteger maxY;
    NSInteger count;
    double sumX;
    double sumY;
} SWComponent;

CGRect SWComponentRect(SWComponent component);
CGPoint SWComponentCentroid(SWComponent component);

SWRaster *SWRegionsBinarized(SWRaster *raster, NSError **error);
NSData *SWRegionsComponents(SWRaster *binary, NSInteger minimumPixels, SWCancelToken *token, NSError **error);
SWRaster *SWRegionsDifference(SWRaster *first, SWRaster *second, NSInteger threshold, NSInteger *changed, NSError **error);
NSData *SWRegionsMerged(SWRaster *mask, NSInteger radius, SWCancelToken *token, NSError **error);
NSInteger SWRegionsMinimumChange(NSInteger total);
