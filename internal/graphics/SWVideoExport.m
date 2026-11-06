//go:build darwin && cgo

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "SWArguments.h"
#import "SWCancelToken.h"
#import "SWError.h"
#import "SWImageNode.h"
#import "SWRaster.h"
#import "SWVideoModel.h"

typedef SWRaster *(^SWExportFrame)(double time, NSError **error);

static BOOL SWExportGIF(NSURL *target, NSArray<NSNumber *> *times, double step, SWExportFrame frame, SWCancelToken *token, NSError **error) {
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)target, (__bridge CFStringRef)UTTypeGIF.identifier, times.count, NULL);
    if (destination == NULL) {
        SWFail(error, SWErrorNameGeneric, @"graphics: create the GIF");
        return NO;
    }
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFLoopCount: @0}});
    NSDictionary *delay = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFDelayTime: @(step / 1000)}};
    NSError *failure = nil;
    for (NSNumber *time in times) {
        @autoreleasepool {
            if ([token failIfCancelled:&failure]) {
                break;
            }
            SWRaster *raster = frame(time.doubleValue, &failure);
            CGImageRef image = raster == nil ? NULL : SWRasterCreateImage(raster, &failure);
            if (image == NULL) {
                break;
            }
            CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)delay);
            CGImageRelease(image);
        }
    }
    BOOL finished = failure == nil && CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (failure != nil) {
        SWFailWith(error, failure);
        return NO;
    }
    if (!finished) {
        SWFail(error, SWErrorNameGeneric, @"graphics: write the GIF");
    }
    return finished;
}

static BOOL SWAppendFrame(AVAssetWriter *writer, AVAssetWriterInputPixelBufferAdaptor *adaptor, SWRaster *raster, CMTime time, NSError **error) {
    CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
    if (pool == NULL) {
        SWFail(error, SWErrorNameGeneric, @"graphics: the video writer has no buffers: %@", writer.error.localizedDescription ?: @"unknown");
        return NO;
    }
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &buffer);
    if (buffer == NULL) {
        SWFail(error, SWErrorNameGeneric, @"graphics: allocate a video frame");
        return NO;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    if (base != NULL) {
        size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
        NSInteger rows = MIN(raster.height, (NSInteger)CVPixelBufferGetHeight(buffer));
        NSInteger columns = MIN(raster.width, (NSInteger)CVPixelBufferGetWidth(buffer));
        const uint8_t *source = raster.data;
        for (NSInteger row = 0; row < rows; row++) {
            memcpy(base + row * rowBytes, source + row * raster.rowBytes, columns * 4);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    BOOL appended = [adaptor appendPixelBuffer:buffer withPresentationTime:time];
    CVPixelBufferRelease(buffer);
    if (!appended) {
        SWFail(error, SWErrorNameGeneric, @"graphics: write the video: %@", writer.error.localizedDescription ?: @"unknown");
    }
    return appended;
}

static BOOL SWExportMovie(NSURL *target, NSString *format, NSArray<NSNumber *> *times, double from, SWExportFrame frame, SWCancelToken *token, NSError **error) {
    SWRaster *first = frame(times[0].doubleValue, error);
    if (first == nil) {
        return NO;
    }
    BOOL mov = [format isEqualToString:@"mov"];
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:target fileType:mov ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4 error:error];
    if (writer == nil) {
        return NO;
    }
    AVAssetWriterInput *input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: mov ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
        AVVideoWidthKey: @(first.width), AVVideoHeightKey: @(first.height),
    }];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:input sourcePixelBufferAttributes:@{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferWidthKey: @(first.width), (__bridge id)kCVPixelBufferHeightKey: @(first.height),
    }];
    if (![writer canAddInput:input]) {
        SWFail(error, SWErrorNameGeneric, @"graphics: create the video writer");
        return NO;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        SWFail(error, SWErrorNameGeneric, @"graphics: start the video: %@", writer.error.localizedDescription ?: @"unknown");
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    NSError *failure = nil;
    for (NSUInteger index = 0; index < times.count && failure == nil; index++) {
        @autoreleasepool {
            if ([token failIfCancelled:&failure]) {
                break;
            }
            double time = times[index].doubleValue;
            SWRaster *raster = index == 0 ? first : frame(time, &failure);
            if (raster == nil) {
                break;
            }
            while (!input.isReadyForMoreMediaData && failure == nil) {
                if (![token failIfCancelled:&failure]) {
                    usleep(2000);
                }
            }
            if (failure == nil) {
                SWAppendFrame(writer, adaptor, raster, CMTimeMake((int64_t)round(time - from), 1000), &failure);
            }
        }
    }
    if (failure != nil) {
        SWFailWith(error, failure);
        return NO;
    }
    [input markAsFinished];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(finished);
    }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        SWFail(error, SWErrorNameGeneric, @"graphics: finish the video: %@", writer.error.localizedDescription ?: @"unknown");
        return NO;
    }
    return YES;
}

NSString *SWVideoExport(SWVideoModel *model, SWArguments *arguments, NSURL *target, SWCancelToken *token, NSError **error) {
    if (![NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    NSString *format = [arguments string:@"format"] ?: @"mp4";
    BOOL gif = [format isEqualToString:@"gif"];
    double from = [arguments double:@"from" fallback:0];
    double to = [arguments double:@"to" fallback:model.duration];
    double rate = [arguments double:@"frameRate" fallback:gif ? 10 : 30];
    double factor = [arguments double:@"scale" fallback:1];
    CGRect region;
    BOOL hasRegion = [arguments rect:@"region" into:&region];
    double step = 1000 / rate;
    NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    for (NSInteger index = 0; from + index * step <= to; index++) {
        [times addObject:@(from + index * step)];
    }
    if (times.count == 0) {
        SWFail(error, SWErrorNameRange, @"graphics: the range has no frames");
        return nil;
    }
    SWExportFrame frame = ^SWRaster *(double time, NSError **failure) {
        SWImageNode *node = [model nodeAt:time];
        SWImageNode *source = hasRegion ? [node cropInSpace:region error:failure] : node;
        SWRaster *raster = source == nil ? nil : [source raster:token error:failure];
        if (raster == nil) {
            return nil;
        }
        NSInteger width = MAX((NSInteger)round(raster.width * factor), 2);
        NSInteger height = MAX((NSInteger)round(raster.height * factor), 2);
        return SWRasterResized(raster, gif ? width : width & ~1, gif ? height : height & ~1, failure);
    };
    BOOL exported = gif ? SWExportGIF(target, times, step, frame, token, error) : SWExportMovie(target, format, times, from, frame, token, error);
    return exported ? target.path : nil;
}
