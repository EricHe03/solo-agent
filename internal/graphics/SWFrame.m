//go:build darwin && cgo

#import "SWFrame.h"

#import <VideoToolbox/VideoToolbox.h>

#import "SWError.h"
#import "SWRaster.h"

API_AVAILABLE(ios(16.0), macos(10.8))
static OSStatus SWTransfer(CVPixelBufferRef source, CVPixelBufferRef destination) {
    static VTPixelTransferSessionRef session;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
    });
    [lock lock];
    OSStatus status = noErr;
    if (session == NULL) {
        status = VTPixelTransferSessionCreate(NULL, &session);
    }
    if (status == noErr) {
        status = VTPixelTransferSessionTransferImage(session, source, destination);
    }
    [lock unlock];
    return status;
}

@implementation SWFrame {
    CVPixelBufferRef _pixelBuffer;
    NSInteger _cropWidth;
    NSInteger _cropHeight;
    NSLock *_quarterLock;
    SWRaster *_quarterPlane;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer time:(double)time turns:(NSInteger)turns geometry:(SWScreenGeometry)geometry {
    self = [super init];
    if (self) {
        _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
        _time = time;
        _turns = turns;
        _geometry = geometry;
        NSInteger width = CVPixelBufferGetWidth(pixelBuffer);
        NSInteger height = CVPixelBufferGetHeight(pixelBuffer);
        _cropWidth = geometry.width > 0 ? MIN(geometry.width, width) : width;
        _cropHeight = geometry.height > 0 ? MIN(geometry.height, height) : height;
        _quarterLock = [NSLock new];
    }
    return self;
}

- (void)dealloc {
    CVPixelBufferRelease(_pixelBuffer);
}

- (NSInteger)pixelWidth {
    return _turns % 2 == 0 ? _cropWidth : _cropHeight;
}

- (NSInteger)pixelHeight {
    return _turns % 2 == 0 ? _cropHeight : _cropWidth;
}

- (SWRaster *)raster:(NSError **)error {
    SWRaster *native = [[SWRaster alloc] initWithPixelBuffer:_pixelBuffer width:_cropWidth height:_cropHeight error:error];
    return native == nil ? nil : SWRasterRotatedQuarters(native, _turns, error);
}

- (SWRaster *)makeQuarter:(NSError **)error {
    NSInteger width = MAX(_cropWidth / 4, 1);
    NSInteger height = MAX(_cropHeight / 4, 1);
    CVPixelBufferRef made = NULL;
    NSDictionary *attributes = @{(__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    NSInteger bufferWidth = MAX((NSInteger)CVPixelBufferGetWidth(_pixelBuffer) / 4, width);
    NSInteger bufferHeight = MAX((NSInteger)CVPixelBufferGetHeight(_pixelBuffer) / 4, height);
    if (CVPixelBufferCreate(NULL, bufferWidth, bufferHeight, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &made) != kCVReturnSuccess) {
        SWFail(error, SWErrorNameGeneric, @"graphics: allocate the scaled frame");
        return nil;
    }
    OSStatus status = kVTPixelTransferNotSupportedErr;
    if (@available(iOS 16.0, macOS 10.8, *)) {
        status = SWTransfer(_pixelBuffer, made);
    }
    if (status != noErr) {
        CVPixelBufferRelease(made);
        SWFail(error, SWErrorNameGeneric, @"graphics: scale the frame (%d)", (int)status);
        return nil;
    }
    SWRaster *scaled = [[SWRaster alloc] initWithPixelBuffer:made width:width height:height error:error];
    CVPixelBufferRelease(made);
    SWRaster *gray = scaled == nil ? nil : SWRasterGrayscale(scaled, error);
    return gray == nil ? nil : SWRasterRotatedQuarters(gray, _turns, error);
}

- (SWRaster *)quarter:(NSError **)error {
    [_quarterLock lock];
    if (_quarterPlane == nil) {
        _quarterPlane = [self makeQuarter:error];
    }
    SWRaster *plane = _quarterPlane;
    [_quarterLock unlock];
    return plane;
}

@end
