//go:build darwin && cgo

#import "SWJSON.h"
#import "SWRaster.h"

NSArray<SWRaster *> *SWRasterPlanes(SWRaster *raster, NSError **error) {
    if (raster.isGray) {
        return @[raster];
    }
    SWRaster *blue = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    SWRaster *green = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    SWRaster *red = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    SWRaster *alpha = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    vImage_Buffer source = raster.buffer;
    vImage_Buffer blueBuffer = blue.buffer;
    vImage_Buffer greenBuffer = green.buffer;
    vImage_Buffer redBuffer = red.buffer;
    vImage_Buffer alphaBuffer = alpha.buffer;
    if (!SWRequire(vImageConvert_ARGB8888toPlanar8(&source, &blueBuffer, &greenBuffer, &redBuffer, &alphaBuffer, kvImageNoFlags), @"split the channels", error)) {
        return nil;
    }
    return @[red, green, blue, alpha];
}

NSDictionary<NSString *, NSArray<NSNumber *> *> *SWRasterStatistics(SWRaster *raster, NSError **error) {
    NSArray<SWRaster *> *planes = SWRasterPlanes(raster, error);
    if (planes == nil) {
        return nil;
    }
    NSMutableArray<NSNumber *> *mean = [NSMutableArray array];
    NSMutableArray<NSNumber *> *low = [NSMutableArray array];
    NSMutableArray<NSNumber *> *high = [NSMutableArray array];
    NSMutableArray<NSNumber *> *deviation = [NSMutableArray array];
    vDSP_Length count = (vDSP_Length)(raster.width * raster.height);
    float *values = malloc(MAX(count, 1) * sizeof(float));
    for (SWRaster *plane in planes) {
        [plane copyFloatsInto:values];
        float average = 0;
        float square = 0;
        float minimum = 0;
        float maximum = 0;
        vDSP_meanv(values, 1, &average, count);
        vDSP_measqv(values, 1, &square, count);
        vDSP_minv(values, 1, &minimum, count);
        vDSP_maxv(values, 1, &maximum, count);
        [mean addObject:@(SWRounded(average))];
        [low addObject:@((double)minimum)];
        [high addObject:@((double)maximum)];
        [deviation addObject:@(SWRounded(sqrt((double)MAX(square - average * average, 0.f))))];
    }
    free(values);
    return @{@"mean": mean, @"min": low, @"max": high, @"deviation": deviation};
}
