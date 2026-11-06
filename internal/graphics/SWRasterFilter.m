//go:build darwin && cgo

#import "SWRaster.h"

SWRaster *SWRasterGrayscale(SWRaster *raster, NSError **error) {
    if (raster.isGray) {
        return raster;
    }
    SWRaster *out = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    vImage_Buffer source = raster.buffer;
    vImage_Buffer destination = out.buffer;
    const int16_t matrix[4] = {29, 150, 77, 0};
    vImage_Error status = vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, matrix, 256, NULL, 0, kvImageNoFlags);
    return SWRequire(status, @"convert the image to gray", error) ? out : nil;
}

SWRaster *SWRasterLookUp(SWRaster *raster, const uint8_t table[256], NSError **error) {
    NS_VALID_UNTIL_END_OF_SCOPE SWRaster *gray = SWRasterGrayscale(raster, error);
    if (gray == nil) {
        return nil;
    }
    SWRaster *out = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    vImage_Buffer source = gray.buffer;
    vImage_Buffer destination = out.buffer;
    return SWRequire(vImageTableLookUp_Planar8(&source, &destination, table, kvImageNoFlags), @"map the image", error) ? out : nil;
}

static BOOL SWOtsu(SWRaster *gray, NSInteger *level, NSError **error) {
    vImagePixelCount histogram[256] = {0};
    vImage_Buffer source = gray.buffer;
    if (!SWRequire(vImageHistogramCalculation_Planar8(&source, histogram, kvImageNoFlags), @"measure the histogram", error)) {
        return NO;
    }
    double total = 0;
    double weighted = 0;
    for (NSInteger value = 0; value < 256; value++) {
        total += (double)histogram[value];
        weighted += (double)value * (double)histogram[value];
    }
    double background = 0;
    double backgroundSum = 0;
    double best = 0;
    *level = 0;
    for (NSInteger value = 0; value < 256; value++) {
        background += (double)histogram[value];
        if (background == 0) {
            continue;
        }
        double foreground = total - background;
        if (foreground == 0) {
            break;
        }
        backgroundSum += (double)value * (double)histogram[value];
        double difference = backgroundSum / background - (weighted - backgroundSum) / foreground;
        double between = background * foreground * difference * difference;
        if (between > best) {
            best = between;
            *level = value;
        }
    }
    return YES;
}

SWRaster *SWRasterThresholded(SWRaster *raster, NSInteger level, NSError **error) {
    SWRaster *gray = SWRasterGrayscale(raster, error);
    if (gray == nil) {
        return nil;
    }
    NSInteger cut = level;
    if (level < 0) {
        if (!SWOtsu(gray, &cut, error)) {
            return nil;
        }
        cut += 1;
    }
    uint8_t table[256];
    for (NSInteger value = 0; value < 256; value++) {
        table[value] = value >= cut ? 255 : 0;
    }
    return SWRasterLookUp(gray, table, error);
}

SWRaster *SWRasterMasked(SWRaster *raster, const uint8_t low[3], const uint8_t high[3], NSError **error) {
    uint8_t table[256];
    if (raster.isGray) {
        NSInteger lower = MAX(MAX(low[0], low[1]), low[2]);
        NSInteger upper = MIN(MIN(high[0], high[1]), high[2]);
        for (NSInteger value = 0; value < 256; value++) {
            table[value] = value >= lower && value <= upper ? 255 : 0;
        }
        return SWRasterLookUp(raster, table, error);
    }
    uint8_t blue[256];
    uint8_t green[256];
    uint8_t red[256];
    const uint8_t alpha[256] = {0};
    for (NSInteger value = 0; value < 256; value++) {
        blue[value] = value >= low[2] && value <= high[2] ? 1 : 0;
        green[value] = value >= low[1] && value <= high[1] ? 2 : 0;
        red[value] = value >= low[0] && value <= high[0] ? 4 : 0;
        table[value] = value == 7 ? 255 : 0;
    }
    NS_VALID_UNTIL_END_OF_SCOPE SWRaster *flags = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:4];
    vImage_Buffer source = raster.buffer;
    vImage_Buffer marked = flags.buffer;
    if (!SWRequire(vImageTableLookUp_ARGB8888(&source, &marked, blue, green, red, alpha, kvImageNoFlags), @"mask the image", error)) {
        return nil;
    }
    SWRaster *sum = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:1];
    vImage_Buffer summed = sum.buffer;
    const int16_t matrix[4] = {1, 1, 1, 0};
    if (!SWRequire(vImageMatrixMultiply_ARGB8888ToPlanar8(&marked, &summed, matrix, 1, NULL, 0, kvImageNoFlags), @"mask the image", error)) {
        return nil;
    }
    return SWRasterLookUp(sum, table, error);
}

SWRaster *SWRasterInverted(SWRaster *raster, NSError **error) {
    uint8_t flipped[256];
    uint8_t same[256];
    for (NSInteger value = 0; value < 256; value++) {
        flipped[value] = (uint8_t)(255 - value);
        same[value] = (uint8_t)value;
    }
    if (raster.isGray) {
        return SWRasterLookUp(raster, flipped, error);
    }
    SWRaster *out = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:4];
    vImage_Buffer source = raster.buffer;
    vImage_Buffer destination = out.buffer;
    return SWRequire(vImageTableLookUp_ARGB8888(&source, &destination, flipped, flipped, flipped, same, kvImageNoFlags), @"invert the image", error) ? out : nil;
}

SWRaster *SWRasterMorphed(SWRaster *raster, NSInteger radius, BOOL dilate, NSError **error) {
    SWRaster *out = [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:raster.channels];
    vImagePixelCount size = (vImagePixelCount)(radius * 2 + 1);
    vImage_Buffer source = raster.buffer;
    vImage_Buffer destination = out.buffer;
    vImage_Error status;
    if (raster.isGray) {
        status = dilate ? vImageMax_Planar8(&source, &destination, NULL, 0, 0, size, size, kvImageNoFlags)
                        : vImageMin_Planar8(&source, &destination, NULL, 0, 0, size, size, kvImageNoFlags);
    } else {
        status = dilate ? vImageMax_ARGB8888(&source, &destination, NULL, 0, 0, size, size, kvImageNoFlags)
                        : vImageMin_ARGB8888(&source, &destination, NULL, 0, 0, size, size, kvImageNoFlags);
    }
    return SWRequire(status, dilate ? @"dilate the image" : @"erode the image", error) ? out : nil;
}
