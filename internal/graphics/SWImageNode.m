//go:build darwin && cgo

#import "SWImageNode.h"

#import <ImageIO/ImageIO.h>

#import "SWCancelToken.h"
#import "SWError.h"
#import "SWFrame.h"
#import "SWJSON.h"
#import "SWRaster.h"
#import "SWVideoModel.h"

typedef SWRaster *(^SWImageSource)(SWCancelToken *token, NSError **error);
typedef SWRaster *(^SWImageOperation)(SWRaster *input, NSError **error);

@implementation SWImageNode {
    SWImageSource _source;
    SWImageNode *_parent;
    SWImageOperation _operation;
    SWRaster *_cached;
    NSLock *_lock;
}

- (instancetype)initWithPixelWidth:(NSInteger)width height:(NSInteger)height transform:(CGAffineTransform)transform gray:(BOOL)gray time:(double)time timestamp:(double)timestamp {
    self = [super init];
    if (self) {
        _pixelWidth = width;
        _pixelHeight = height;
        _transform = transform;
        _gray = gray;
        _time = time;
        _timestamp = timestamp;
        _lock = [NSLock new];
    }
    return self;
}

+ (instancetype)nodeWithEncoded:(NSData *)data scale:(NSNumber *)scale timestamp:(double)timestamp error:(NSError **)error {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    NSDictionary *properties = source == NULL ? nil : CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    if (source != NULL) {
        CFRelease(source);
    }
    NSInteger width = SWAsNumber(properties[(__bridge id)kCGImagePropertyPixelWidth]).integerValue;
    NSInteger height = SWAsNumber(properties[(__bridge id)kCGImagePropertyPixelHeight]).integerValue;
    if (width <= 0 || height <= 0) {
        SWFail(error, SWErrorNameData, @"graphics: the bytes are not an image");
        return nil;
    }
    if (SWAsNumber(properties[(__bridge id)kCGImagePropertyOrientation]).integerValue >= 5) {
        NSInteger swapped = width;
        width = height;
        height = swapped;
    }
    double chosen = 1;
    NSNumber *dpi = SWAsNumber(properties[(__bridge id)kCGImagePropertyDPIWidth]);
    if (scale != nil) {
        chosen = scale.doubleValue;
    } else if (dpi != nil && dpi.doubleValue / 72 >= 1 && dpi.doubleValue / 72 <= 16) {
        chosen = dpi.doubleValue / 72;
    }
    SWImageNode *node = [[self alloc] initWithPixelWidth:width height:height transform:CGAffineTransformMakeScale(1 / chosen, 1 / chosen) gray:NO time:NAN timestamp:timestamp];
    node->_source = ^SWRaster *(SWCancelToken *token, NSError **failure) {
        return SWRasterDecode(data, failure);
    };
    return node;
}

+ (instancetype)nodeWithFrame:(SWFrame *)frame time:(double)time timestamp:(double)timestamp {
    double scale = frame.geometry.scale;
    SWImageNode *node = [[self alloc] initWithPixelWidth:frame.pixelWidth height:frame.pixelHeight transform:CGAffineTransformMakeScale(1 / scale, 1 / scale) gray:NO time:time timestamp:timestamp];
    node->_screenFrame = frame;
    node->_source = ^SWRaster *(SWCancelToken *token, NSError **failure) {
        return [frame raster:failure];
    };
    return node;
}

+ (instancetype)nodeWithFrame:(SWFrame *)frame {
    return [self nodeWithFrame:frame time:NAN timestamp:frame.time];
}

+ (instancetype)nodeWithFrame:(SWFrame *)frame ofVideo:(SWVideoModel *)model {
    return [self nodeWithFrame:frame time:frame.time timestamp:model.start + frame.time];
}

+ (instancetype)nodeWithVideo:(SWVideoModel *)model time:(double)time {
    NSInteger width = 0;
    NSInteger height = 0;
    [model pixelSizeAt:time width:&width height:&height];
    SWImageNode *node = [[self alloc] initWithPixelWidth:width height:height transform:CGAffineTransformMakeScale(1 / model.scale, 1 / model.scale) gray:NO time:time timestamp:model.start + time];
    node->_source = ^SWRaster *(SWCancelToken *token, NSError **failure) {
        return [model rasterAt:time token:token error:failure];
    };
    return node;
}

+ (instancetype)nodeWithRaster:(SWRaster *)raster transform:(CGAffineTransform)transform {
    SWImageNode *node = [[self alloc] initWithPixelWidth:raster.width height:raster.height transform:transform gray:raster.isGray time:NAN timestamp:NAN];
    node->_source = ^SWRaster *(SWCancelToken *token, NSError **failure) {
        return raster;
    };
    return node;
}

- (SWImageNode *)derive:(SWImageOperation)operation width:(NSInteger)width height:(NSInteger)height transform:(CGAffineTransform)transform gray:(BOOL)gray {
    SWImageNode *node = [[SWImageNode alloc] initWithPixelWidth:width height:height transform:transform gray:gray time:_time timestamp:_timestamp];
    node->_parent = self;
    node->_operation = [operation copy];
    return node;
}

- (double)scale {
    return 1 / sqrt(fabs(_transform.a * _transform.d - _transform.b * _transform.c));
}

- (CGRect)frame {
    return CGRectApplyAffineTransform(CGRectMake(0, 0, _pixelWidth, _pixelHeight), _transform);
}

- (NSInteger)estimatedBytes {
    return _pixelWidth * _pixelHeight * (_gray ? 1 : 4);
}

static NSString *SWDescribeRect(CGRect rect) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *number in SWRectJSON(rect)) {
        [parts addObject:[NSString stringWithFormat:@"%g", number.doubleValue]];
    }
    return [parts componentsJoinedByString:@", "];
}

- (BOOL)pixelRectInSpace:(CGRect)rect into:(CGRect *)pixels error:(NSError **)error {
    CGRect mapped = CGRectIntersection(CGRectApplyAffineTransform(rect, CGAffineTransformInvert(_transform)), CGRectMake(0, 0, _pixelWidth, _pixelHeight));
    CGFloat left = floor(CGRectGetMinX(mapped) + 1e-6);
    CGFloat top = floor(CGRectGetMinY(mapped) + 1e-6);
    CGFloat right = ceil(CGRectGetMaxX(mapped) - 1e-6);
    CGFloat bottom = ceil(CGRectGetMaxY(mapped) - 1e-6);
    if (CGRectIsNull(mapped) || right - left < 1 || bottom - top < 1) {
        SWFail(error, SWErrorNameRange, @"[%@] does not overlap the image [%@]", SWDescribeRect(rect), SWDescribeRect(self.frame));
        return NO;
    }
    *pixels = CGRectMake(left, top, right - left, bottom - top);
    return YES;
}

- (CGPoint)pixelPointInSpace:(CGPoint)point {
    return CGPointApplyAffineTransform(point, CGAffineTransformInvert(_transform));
}

- (NSArray<NSNumber *> *)spacePoint:(CGPoint)point {
    return SWPointJSON(CGPointApplyAffineTransform(point, _transform));
}

- (CGRect)spaceRect:(CGRect)rect {
    return CGRectApplyAffineTransform(rect, _transform);
}

- (SWImageNode *)cropInSpace:(CGRect)rect error:(NSError **)error {
    CGRect pixels;
    if (![self pixelRectInSpace:rect into:&pixels error:error]) {
        return nil;
    }
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        return [input viewOfRect:pixels];
    } width:(NSInteger)CGRectGetWidth(pixels) height:(NSInteger)CGRectGetHeight(pixels)
        transform:CGAffineTransformConcat(CGAffineTransformMakeTranslation(CGRectGetMinX(pixels), CGRectGetMinY(pixels)), _transform) gray:_gray];
}

- (SWImageNode *)resizeToWidth:(NSInteger)width height:(NSInteger)height {
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        return SWRasterResized(input, width, height, failure);
    } width:width height:height
        transform:CGAffineTransformConcat(CGAffineTransformMakeScale((CGFloat)_pixelWidth / width, (CGFloat)_pixelHeight / height), _transform) gray:_gray];
}

- (SWImageNode *)rotateDegrees:(double)degrees {
    double turned = fmod(degrees, 360);
    double normalized = turned < 0 ? turned + 360 : turned;
    if (normalized == 0) {
        return self;
    }
    double angle = normalized * M_PI / 180;
    BOOL quarter = fmod(normalized, 90) == 0;
    NSInteger turns = (NSInteger)normalized / 90;
    NSInteger width = quarter ? (turns % 2 == 0 ? _pixelWidth : _pixelHeight)
                              : (NSInteger)ceil(fabs(_pixelWidth * cos(angle)) + fabs(_pixelHeight * sin(angle)) - 1e-6);
    NSInteger height = quarter ? (turns % 2 == 0 ? _pixelHeight : _pixelWidth)
                               : (NSInteger)ceil(fabs(_pixelWidth * sin(angle)) + fabs(_pixelHeight * cos(angle)) - 1e-6);
    CGAffineTransform toParent = CGAffineTransformConcat(
        CGAffineTransformConcat(CGAffineTransformMakeTranslation(-(CGFloat)width / 2, -(CGFloat)height / 2), CGAffineTransformMakeRotation(-angle)),
        CGAffineTransformMakeTranslation((CGFloat)_pixelWidth / 2, (CGFloat)_pixelHeight / 2));
    NSInteger outWidth = MAX(width, 1);
    NSInteger outHeight = MAX(height, 1);
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        if (quarter) {
            return SWRasterRotatedQuarters(input, turns, failure);
        }
        return SWRasterRotatedDegrees(input, normalized, outWidth, outHeight, failure);
    } width:outWidth height:outHeight transform:CGAffineTransformConcat(toParent, _transform) gray:_gray];
}

- (SWImageNode *)grayscaleNode {
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        return SWRasterGrayscale(input, failure);
    } width:_pixelWidth height:_pixelHeight transform:_transform gray:YES];
}

- (SWImageNode *)thresholdNode:(NSInteger)level {
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        return SWRasterThresholded(input, level, failure);
    } width:_pixelWidth height:_pixelHeight transform:_transform gray:YES];
}

- (SWImageNode *)maskNodeLow:(const uint8_t[3])low high:(const uint8_t[3])high {
    uint8_t lowRed = low[0], lowGreen = low[1], lowBlue = low[2];
    uint8_t highRed = high[0], highGreen = high[1], highBlue = high[2];
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        const uint8_t lower[3] = {lowRed, lowGreen, lowBlue};
        const uint8_t upper[3] = {highRed, highGreen, highBlue};
        return SWRasterMasked(input, lower, upper, failure);
    } width:_pixelWidth height:_pixelHeight transform:_transform gray:YES];
}

- (SWImageNode *)invertNode {
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        return SWRasterInverted(input, failure);
    } width:_pixelWidth height:_pixelHeight transform:_transform gray:_gray];
}

- (SWImageNode *)morphNode:(NSInteger)radius dilate:(BOOL)dilate {
    return [self derive:^SWRaster *(SWRaster *input, NSError **failure) {
        return SWRasterMorphed(input, radius, dilate, failure);
    } width:_pixelWidth height:_pixelHeight transform:_transform gray:_gray];
}

- (SWRaster *)cachedRaster {
    [_lock lock];
    SWRaster *cached = _cached;
    [_lock unlock];
    return cached;
}

- (SWRaster *)raster:(SWCancelToken *)token error:(NSError **)error {
    SWRaster *cached = self.cachedRaster;
    if (cached != nil) {
        return cached;
    }
    SWRaster *rendered = [self render:token error:error];
    if (rendered == nil) {
        return nil;
    }
    [_lock lock];
    _cached = rendered;
    _parent = nil;
    _operation = nil;
    [_lock unlock];
    return rendered;
}

- (SWRaster *)render:(SWCancelToken *)token error:(NSError **)error {
    if (_source == nil) {
        [_lock lock];
        SWImageNode *parent = _parent;
        SWImageOperation operation = _operation;
        [_lock unlock];
        if (parent == nil) {
            return [self raster:token error:error];
        }
        SWRaster *input = parent.cachedRaster ?: [parent render:token error:error];
        if (input == nil || [token failIfCancelled:error]) {
            return nil;
        }
        return operation(input, error);
    }
    SWRaster *raster = _source(token, error);
    if (raster == nil) {
        return nil;
    }
    if (raster.width != _pixelWidth || raster.height != _pixelHeight) {
        raster = SWRasterResized(raster, _pixelWidth, _pixelHeight, error);
        if (raster == nil) {
            return nil;
        }
    }
    [_lock lock];
    _cached = raster;
    [_lock unlock];
    return raster;
}

- (SWRaster *)rasterInSpace:(const CGRect *)rect origin:(CGPoint *)origin token:(SWCancelToken *)token error:(NSError **)error {
    SWRaster *raster = [self raster:token error:error];
    if (raster == nil || rect == NULL) {
        return raster;
    }
    CGRect pixels;
    if (![self pixelRectInSpace:*rect into:&pixels error:error]) {
        return nil;
    }
    if (origin != NULL) {
        *origin = pixels.origin;
    }
    return [raster viewOfRect:pixels];
}

@end
