//go:build darwin && cgo

#import "SWScreenComparison.h"

#import "SWFrame.h"
#import "SWImageNode.h"
#import "SWRaster.h"
#import "SWRegions.h"

@implementation SWScreenComparison {
    CGRect _region;
    NSInteger _width;
    NSInteger _height;
    NSInteger _threshold;
    BOOL _shared;
}

- (instancetype)initWithNode:(SWImageNode *)node region:(const CGRect *)region threshold:(NSInteger)threshold error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    CGRect area = region == NULL ? node.frame : *region;
    CGRect pixels;
    if (![node pixelRectInSpace:area into:&pixels error:error]) {
        return nil;
    }
    double factor = MIN(CGRectGetWidth(pixels), CGRectGetHeight(pixels)) >= 64 ? 4 : 1;
    _region = area;
    _width = MAX((NSInteger)(CGRectGetWidth(pixels) / factor), 1);
    _height = MAX((NSInteger)(CGRectGetHeight(pixels) / factor), 1);
    _threshold = threshold;
    _shared = factor == 4 && node.screenFrame != nil;
    return self;
}

- (SWRaster *)plane:(SWImageNode *)node token:(SWCancelToken *)token error:(NSError **)error {
    CGRect pixels;
    if (![node pixelRectInSpace:_region into:&pixels error:error]) {
        return nil;
    }
    SWFrame *frame = node.screenFrame;
    if (_shared && frame != nil) {
        SWRaster *quarter = [frame quarter:error];
        if (quarter == nil) {
            return nil;
        }
        NSInteger x = MIN((NSInteger)CGRectGetMinX(pixels) / 4, quarter.width - _width);
        NSInteger y = MIN((NSInteger)CGRectGetMinY(pixels) / 4, quarter.height - _height);
        return [quarter viewOfRect:CGRectMake(MAX(x, 0), MAX(y, 0), MIN(_width, quarter.width), MIN(_height, quarter.height))];
    }
    SWRaster *raster = [node raster:token error:error];
    if (raster == nil) {
        return nil;
    }
    SWRaster *resized = SWRasterResized([raster viewOfRect:pixels], _width, _height, error);
    return resized == nil ? nil : SWRasterGrayscale(resized, error);
}

- (BOOL)changed:(SWRaster *)first from:(SWRaster *)second result:(BOOL *)result error:(NSError **)error {
    NSInteger changed = 0;
    if (SWRegionsDifference(first, second, _threshold, &changed, error) == nil) {
        return NO;
    }
    *result = changed >= SWRegionsMinimumChange(first.width * first.height);
    return YES;
}

@end
