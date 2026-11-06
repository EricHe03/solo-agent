//go:build darwin && cgo

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "SWError.h"
#import "SWJSON.h"
#import "SWRaster.h"

static vImage_CGImageFormat SWColorFormat(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    return (vImage_CGImageFormat){.bitsPerComponent = 8, .bitsPerPixel = 32, .colorSpace = space, .bitmapInfo = (CGBitmapInfo)kCGImageAlphaFirst | kCGBitmapByteOrder32Little};
}

static vImage_CGImageFormat SWGrayFormat(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        space = CGColorSpaceCreateDeviceGray();
    });
    return (vImage_CGImageFormat){.bitsPerComponent = 8, .bitsPerPixel = 8, .colorSpace = space, .bitmapInfo = (CGBitmapInfo)kCGImageAlphaNone};
}

SWRaster *SWRasterFromImage(CGImageRef image, NSError **error) {
    vImage_CGImageFormat format = SWColorFormat();
    vImage_Buffer decoded = {0};
    if (!SWRequire(vImageBuffer_InitWithCGImage(&decoded, &format, NULL, image, kvImageNoFlags), @"read the image", error)) {
        return nil;
    }
    return [[SWRaster alloc] initAdoptingBytes:decoded.data width:(NSInteger)decoded.width height:(NSInteger)decoded.height rowBytes:(NSInteger)decoded.rowBytes];
}

SWRaster *SWRasterDecode(NSData *data, NSError **error) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (source == NULL) {
        SWFail(error, SWErrorNameData, @"graphics: the bytes are not an image");
        return nil;
    }
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSNumber *orientation = SWAsNumber(properties[(__bridge id)kCGImagePropertyOrientation]);
    CGImageRef image;
    if (orientation == nil || orientation.integerValue == 1) {
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(__bridge id)kCGImageSourceShouldCacheImmediately: @YES});
    } else {
        NSInteger side = MAX(SWAsNumber(properties[(__bridge id)kCGImagePropertyPixelWidth]).integerValue, SWAsNumber(properties[(__bridge id)kCGImagePropertyPixelHeight]).integerValue);
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
            (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(side, 1)),
            (__bridge id)kCGImageSourceShouldCacheImmediately: @YES,
        });
    }
    CFRelease(source);
    if (image == NULL) {
        SWFail(error, SWErrorNameData, @"graphics: the image could not be decoded");
        return nil;
    }
    SWRaster *raster = SWRasterFromImage(image, error);
    CGImageRelease(image);
    return raster;
}

CGImageRef SWRasterCreateImage(SWRaster *raster, NSError **error) {
    vImage_Buffer buffer = raster.buffer;
    vImage_CGImageFormat format = raster.isGray ? SWGrayFormat() : SWColorFormat();
    vImage_Error status = kvImageNoError;
    CGImageRef image = vImageCreateCGImageFromBuffer(&buffer, &format, NULL, NULL, kvImageNoFlags, &status);
    if (image == NULL) {
        SWRequire(status, @"create the image", error);
    }
    return image;
}

NSData *SWRasterEncode(SWRaster *raster, NSString *format, NSNumber *quality, double scale, NSError **error) {
    UTType *type = UTTypePNG;
    if ([format isEqualToString:@"jpeg"]) {
        type = UTTypeJPEG;
    } else if ([format isEqualToString:@"heic"]) {
        type = UTTypeHEIC;
    }
    CGImageRef image = SWRasterCreateImage(raster, error);
    if (image == NULL) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)type.identifier, 1, NULL);
    if (destination == NULL) {
        CGImageRelease(image);
        SWFail(error, SWErrorNameGeneric, @"graphics: create the %@ encoder", format);
        return nil;
    }
    NSMutableDictionary *properties = [@{(__bridge id)kCGImagePropertyDPIWidth: @(72 * scale), (__bridge id)kCGImagePropertyDPIHeight: @(72 * scale)} mutableCopy];
    if (quality != nil) {
        properties[(__bridge id)kCGImageDestinationLossyCompressionQuality] = quality;
    }
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL finished = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    if (!finished) {
        SWFail(error, SWErrorNameGeneric, @"graphics: encode the image as %@", format);
        return nil;
    }
    return data;
}
