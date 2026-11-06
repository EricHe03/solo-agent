//go:build darwin && cgo

#import "SWRaster.h"

#import "SWError.h"

@interface SWRasterStorage : NSObject
@property (nonatomic, readonly) uint8_t *base NS_RETURNS_INNER_POINTER;

- (instancetype)initAdopting:(void *)bytes;
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError **)error;
@end

@implementation SWRasterStorage {
    CVPixelBufferRef _pixelBuffer;
}

- (instancetype)initAdopting:(void *)bytes {
    self = [super init];
    if (self) {
        _base = bytes;
    }
    return self;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        SWFail(error, SWErrorNameGeneric, @"graphics: lock the frame");
        return nil;
    }
    _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    _base = CVPixelBufferGetBaseAddress(pixelBuffer);
    if (_base == NULL) {
        SWFail(error, SWErrorNameGeneric, @"graphics: the frame has no pixels");
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_pixelBuffer != NULL) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(_pixelBuffer);
    } else {
        free(_base);
    }
}

@end

@implementation SWRaster {
    SWRasterStorage *_storage;
}

- (instancetype)initWithStorage:(SWRasterStorage *)storage data:(uint8_t *)data width:(NSInteger)width height:(NSInteger)height rowBytes:(NSInteger)rowBytes channels:(NSInteger)channels {
    self = [super init];
    if (self) {
        _storage = storage;
        _data = data;
        _width = width;
        _height = height;
        _rowBytes = rowBytes;
        _channels = channels;
    }
    return self;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height channels:(NSInteger)channels {
    NSInteger rowBytes = (width * channels + 15) & ~15;
    void *bytes = NULL;
    if (posix_memalign(&bytes, 64, MAX(rowBytes * height, 1)) != 0) {
        return nil;
    }
    SWRasterStorage *storage = [[SWRasterStorage alloc] initAdopting:bytes];
    return [self initWithStorage:storage data:storage.base width:width height:height rowBytes:rowBytes channels:channels];
}

- (instancetype)initAdoptingBytes:(void *)bytes width:(NSInteger)width height:(NSInteger)height rowBytes:(NSInteger)rowBytes {
    SWRasterStorage *storage = [[SWRasterStorage alloc] initAdopting:bytes];
    return [self initWithStorage:storage data:storage.base width:width height:height rowBytes:rowBytes channels:4];
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer width:(NSInteger)width height:(NSInteger)height error:(NSError **)error {
    SWRasterStorage *storage = [[SWRasterStorage alloc] initWithPixelBuffer:pixelBuffer error:error];
    if (storage == nil) {
        return nil;
    }
    return [self initWithStorage:storage data:storage.base width:width height:height rowBytes:CVPixelBufferGetBytesPerRow(pixelBuffer) channels:4];
}

- (BOOL)isGray {
    return _channels == 1;
}

- (vImage_Buffer)buffer {
    return (vImage_Buffer){.data = _data, .height = (vImagePixelCount)_height, .width = (vImagePixelCount)_width, .rowBytes = (size_t)_rowBytes};
}

- (SWRaster *)viewOfRect:(CGRect)pixels {
    NSInteger x = (NSInteger)CGRectGetMinX(pixels);
    NSInteger y = (NSInteger)CGRectGetMinY(pixels);
    return [[SWRaster alloc] initWithStorage:_storage data:_data + y * _rowBytes + x * _channels width:(NSInteger)CGRectGetWidth(pixels) height:(NSInteger)CGRectGetHeight(pixels) rowBytes:_rowBytes channels:_channels];
}

- (void)readPixelAtX:(NSInteger)x y:(NSInteger)y into:(NSInteger[4])pixel {
    const uint8_t *pointer = _data + y * _rowBytes + x * _channels;
    if (self.isGray) {
        pixel[0] = pixel[1] = pixel[2] = pointer[0];
        pixel[3] = 255;
        return;
    }
    pixel[0] = pointer[2];
    pixel[1] = pointer[1];
    pixel[2] = pointer[0];
    pixel[3] = pointer[3];
}

- (void)copyInto:(SWRaster *)destination x:(NSInteger)x y:(NSInteger)y {
    NSInteger columns = MIN(_width, destination.width - x);
    if (columns <= 0 || _channels != destination.channels) {
        return;
    }
    uint8_t *target = destination.data;
    NSInteger rows = MIN(_height, destination.height - y);
    for (NSInteger row = 0; row < rows; row++) {
        memcpy(target + (y + row) * destination.rowBytes + x * _channels, _data + row * _rowBytes, columns * _channels);
    }
}

- (void)copyFloatsInto:(float *)values {
    for (NSInteger y = 0; y < _height; y++) {
        vDSP_vfltu8(_data + y * _rowBytes, 1, values + y * _width, 1, (vDSP_Length)_width);
    }
}

@end

BOOL SWRequire(vImage_Error status, NSString *operation, NSError **error) {
    if (status == kvImageNoError) {
        return YES;
    }
    SWFail(error, SWErrorNameGeneric, @"graphics: %@: vImage error %ld", operation, (long)status);
    return NO;
}
