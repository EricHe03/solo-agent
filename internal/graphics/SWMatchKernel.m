//go:build darwin && cgo

#import "SWMatchKernel.h"

#import "SWError.h"
#import "SWRaster.h"

@implementation SWPlane

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _values = calloc(MAX(width * height, 1), sizeof(float));
    }
    return self;
}

- (instancetype)initWithRaster:(SWRaster *)raster error:(NSError **)error {
    NS_VALID_UNTIL_END_OF_SCOPE SWRaster *gray = SWRasterGrayscale(raster, error);
    if (gray == nil) {
        return nil;
    }
    self = [self initWithWidth:raster.width height:raster.height];
    if (self) {
        [gray copyFloatsInto:_values];
        float scale = 1.f / 255;
        vDSP_vsmul(_values, 1, &scale, _values, 1, (vDSP_Length)(_width * _height));
    }
    return self;
}

- (void)dealloc {
    free(_values);
}

- (SWPlane *)scaledToWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error {
    SWPlane *out = [[SWPlane alloc] initWithWidth:width height:height];
    vImage_Buffer input = {.data = _values, .height = (vImagePixelCount)_height, .width = (vImagePixelCount)_width, .rowBytes = (size_t)_width * 4};
    vImage_Buffer output = {.data = out.values, .height = (vImagePixelCount)height, .width = (vImagePixelCount)width, .rowBytes = (size_t)width * 4};
    return SWRequire(vImageScale_PlanarF(&input, &output, NULL, kvImageHighQualityResampling), @"scale the plane", error) ? out : nil;
}

- (SWPlane *)squares {
    SWPlane *out = [[SWPlane alloc] initWithWidth:_width height:_height];
    vDSP_vsq(_values, 1, out.values, 1, (vDSP_Length)(_width * _height));
    return out;
}

@end

@implementation SWKernel

- (instancetype)initWithValues:(SWPlane *)values weights:(SWPlane *)weights error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    NSInteger size = values.width * values.height;
    vDSP_Length count = (vDSP_Length)size;
    float weightSum = 0;
    vDSP_sve(weights.values, 1, &weightSum, count);
    if (weightSum <= 0.5f) {
        SWFail(error, SWErrorNameRange, @"the template is transparent");
        return nil;
    }
    float *weighted = malloc(MAX(size, 1) * sizeof(float));
    vDSP_vmul(values.values, 1, weights.values, 1, weighted, 1, count);
    float total = 0;
    vDSP_sve(weighted, 1, &total, count);
    free(weighted);
    float negativeMean = -total / weightSum;
    float *difference = malloc(MAX(size, 1) * sizeof(float));
    vDSP_vsadd(values.values, 1, &negativeMean, difference, 1, count);
    SWPlane *centered = [[SWPlane alloc] initWithWidth:values.width height:values.height];
    vDSP_vmul(difference, 1, weights.values, 1, centered.values, 1, count);
    float variance = 0;
    vDSP_dotpr(centered.values, 1, difference, 1, &variance, count);
    free(difference);
    _width = values.width;
    _height = values.height;
    _centered = centered;
    _weights = weights;
    _weightSum = weightSum;
    _variance = variance;
    return self;
}

@end

@implementation SWColorKernel {
    NSInteger _width;
    NSInteger _height;
    NSArray<SWPlane *> *_centered;
    SWPlane *_weights;
    float _weightSum;
    float _variance;
}

- (instancetype)initWithTemplate:(SWRaster *)template alpha:(SWPlane *)alpha error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    NSArray<SWRaster *> *planes = SWRasterPlanes(template, error);
    if (planes == nil) {
        return nil;
    }
    NSMutableArray<SWPlane *> *centered = [NSMutableArray array];
    float variance = 0;
    for (NSNumber *channel in @[@2, @1, @0]) {
        SWPlane *values = [[SWPlane alloc] initWithRaster:planes[channel.integerValue] error:error];
        if (values == nil) {
            return nil;
        }
        SWKernel *kernel = [[SWKernel alloc] initWithValues:values weights:alpha error:error];
        if (kernel == nil) {
            return nil;
        }
        [centered addObject:kernel.centered];
        variance += kernel.variance;
    }
    float weightSum = 0;
    vDSP_sve(alpha.values, 1, &weightSum, (vDSP_Length)(alpha.width * alpha.height));
    _width = template.width;
    _height = template.height;
    _centered = centered;
    _weights = alpha;
    _weightSum = weightSum;
    _variance = variance;
    return self;
}

- (float)scoreIn:(SWRaster *)target x:(NSInteger)x y:(NSInteger)y {
    float correlation = 0;
    float spread = 0;
    float scale = 1.f / 255;
    vDSP_Length count = (vDSP_Length)_width;
    float *values = malloc(MAX(_width, 1) * sizeof(float));
    const uint8_t *base = target.data;
    NSInteger rowBytes = target.rowBytes;
    const float *weights = _weights.values;
    for (NSInteger channel = 0; channel < 3; channel++) {
        const float *kernel = _centered[channel].values;
        float sum = 0;
        float square = 0;
        for (NSInteger line = 0; line < _height; line++) {
            vDSP_vfltu8(base + (y + line) * rowBytes + x * 4 + channel, 4, values, 1, count);
            vDSP_vsmul(values, 1, &scale, values, 1, count);
            float part = 0;
            vDSP_dotpr(values, 1, kernel + line * _width, 1, &part, count);
            correlation += part;
            vDSP_dotpr(values, 1, weights + line * _width, 1, &part, count);
            sum += part;
            vDSP_vsq(values, 1, values, 1, count);
            vDSP_dotpr(values, 1, weights + line * _width, 1, &part, count);
            square += part;
        }
        spread += MAX(square - sum * sum / _weightSum, 0.f);
    }
    free(values);
    if (spread <= 1.6e-5f * _weightSum * 3 || _variance <= 0) {
        return 0;
    }
    return correlation / sqrtf(_variance * spread);
}

@end

SWPlane *SWTemplateWeights(SWRaster *template, NSError **error) {
    if (template.isGray) {
        SWPlane *ones = [[SWPlane alloc] initWithWidth:template.width height:template.height];
        float one = 1;
        vDSP_vfill(&one, ones.values, 1, (vDSP_Length)(template.width * template.height));
        return ones;
    }
    NSArray<SWRaster *> *planes = SWRasterPlanes(template, error);
    return planes == nil ? nil : [[SWPlane alloc] initWithRaster:planes[3] error:error];
}
