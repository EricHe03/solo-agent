//go:build darwin && cgo

#import "SWError.h"
#import "SWRaster.h"

SWRaster *SWRasterResized(SWRaster *raster, NSInteger width, NSInteger height, NSError **error) {
    if (width == raster.width && height == raster.height) {
        return raster;
    }
    SWRaster *out = [[SWRaster alloc] initWithWidth:width height:height channels:raster.channels];
    vImage_Buffer source = raster.buffer;
    vImage_Buffer destination = out.buffer;
    vImage_Error status = raster.isGray ? vImageScale_Planar8(&source, &destination, NULL, kvImageHighQualityResampling)
                                        : vImageScale_ARGB8888(&source, &destination, NULL, kvImageHighQualityResampling);
    return SWRequire(status, @"resize the image", error) ? out : nil;
}

SWRaster *SWRasterRotatedQuarters(SWRaster *raster, NSInteger quarterTurns, NSError **error) {
    NSInteger turns = ((quarterTurns % 4) + 4) % 4;
    if (turns == 0) {
        return raster;
    }
    SWRaster *out = turns % 2 == 0 ? [[SWRaster alloc] initWithWidth:raster.width height:raster.height channels:raster.channels]
                                   : [[SWRaster alloc] initWithWidth:raster.height height:raster.width channels:raster.channels];
    const uint8_t constants[] = {kRotate0DegreesClockwise, kRotate90DegreesClockwise, kRotate180DegreesClockwise, kRotate270DegreesClockwise};
    vImage_Buffer source = raster.buffer;
    vImage_Buffer destination = out.buffer;
    vImage_Error status;
    if (raster.isGray) {
        status = vImageRotate90_Planar8(&source, &destination, constants[turns], 0, kvImageNoFlags);
    } else {
        const Pixel_8888 back = {0, 0, 0, 0};
        status = vImageRotate90_ARGB8888(&source, &destination, constants[turns], back, kvImageNoFlags);
    }
    return SWRequire(status, @"rotate the image", error) ? out : nil;
}

SWRaster *SWRasterRotatedDegrees(SWRaster *raster, double degrees, NSInteger width, NSInteger height, NSError **error) {
    SWRaster *out = [[SWRaster alloc] initWithWidth:width height:height channels:raster.channels];
    memset(out.data, 0, out.rowBytes * height);
    CGImageRef image = SWRasterCreateImage(raster, error);
    if (image == NULL) {
        return nil;
    }
    CGColorSpaceRef space = raster.isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint32_t info = raster.isGray ? (uint32_t)kCGImageAlphaNone : (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little;
    CGContextRef context = CGBitmapContextCreate(out.data, width, height, 8, out.rowBytes, space, info);
    CGColorSpaceRelease(space);
    if (context == NULL) {
        CGImageRelease(image);
        SWFail(error, SWErrorNameGeneric, @"graphics: create the drawing context");
        return nil;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, width / 2.0, height / 2.0);
    CGContextRotateCTM(context, degrees * M_PI / 180);
    CGContextTranslateCTM(context, -raster.width / 2.0, -raster.height / 2.0);
    CGContextTranslateCTM(context, 0, raster.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, raster.width, raster.height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    if (!raster.isGray) {
        vImage_Buffer buffer = out.buffer;
        if (!SWRequire(vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, kvImageNoFlags), @"unpremultiply the image", error)) {
            return nil;
        }
    }
    return out;
}
