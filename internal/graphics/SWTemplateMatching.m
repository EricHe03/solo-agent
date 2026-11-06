//go:build darwin && cgo

#import "SWTemplateMatching.h"

#import "SWCancelToken.h"
#import "SWError.h"
#import "SWMatchKernel.h"
#import "SWRaster.h"

static const NSInteger SWCoarsestSide = 8;
enum { SWDeepestLevel = 5 };
static const NSInteger SWRefineRadius = 2;

@implementation SWMatch

- (instancetype)initWithRect:(CGRect)rect score:(double)score scale:(double)scale {
    self = [super init];
    if (self) {
        _rect = rect;
        _score = score;
        _scale = scale;
    }
    return self;
}

@end

@interface SWMatchLevel : NSObject
@property (nonatomic, readonly) SWPlane *image;
@property (nonatomic, readonly) SWPlane *squared;
@property (nonatomic, readonly) SWKernel *kernel;
@end

@implementation SWMatchLevel

- (instancetype)initWithImage:(SWPlane *)image kernel:(SWKernel *)kernel {
    self = [super init];
    if (self) {
        _image = image;
        _squared = image.squares;
        _kernel = kernel;
    }
    return self;
}

@end

typedef struct {
    const float *image;
    const float *squared;
    const float *centered;
    const float *weights;
    NSInteger imageWidth;
    NSInteger imageHeight;
    NSInteger width;
    NSInteger height;
    float weightSum;
    float variance;
} SWLevelView;

typedef struct {
    float score;
    NSInteger x;
    NSInteger y;
} SWCandidate;

typedef struct {
    NSInteger x;
    NSInteger y;
} SWPosition;

static SWLevelView SWViewOf(SWMatchLevel *level) {
    SWKernel *kernel = level.kernel;
    return (SWLevelView){
        .image = level.image.values, .squared = level.squared.values, .centered = kernel.centered.values, .weights = kernel.weights.values,
        .imageWidth = level.image.width, .imageHeight = level.image.height, .width = kernel.width, .height = kernel.height,
        .weightSum = kernel.weightSum, .variance = kernel.variance,
    };
}

static float SWFlat(float weightSum) {
    return 1.6e-5f * weightSum;
}

static float *SWCorrelate(const float *image, NSInteger width, NSInteger height, const float *kernel, NSInteger kernelWidth, NSInteger kernelHeight) {
    NSInteger rows = height - kernelHeight + 1;
    float *total = calloc(rows * width, sizeof(float));
    float *part = calloc(rows * width, sizeof(float));
    vDSP_Length length = (vDSP_Length)(rows * width - (kernelWidth - 1));
    for (NSInteger line = 0; line < kernelHeight; line++) {
        vDSP_conv(image + line * width, 1, kernel + line * kernelWidth, 1, part, 1, length, (vDSP_Length)kernelWidth);
        vDSP_vadd(total, 1, part, 1, total, 1, length);
    }
    free(part);
    return total;
}

static float SWScore(const SWLevelView *level, NSInteger x, NSInteger y) {
    float correlation = 0;
    float sum = 0;
    float square = 0;
    vDSP_Length count = (vDSP_Length)level->width;
    for (NSInteger line = 0; line < level->height; line++) {
        NSInteger offset = (y + line) * level->imageWidth + x;
        NSInteger template = line * level->width;
        float part = 0;
        vDSP_dotpr(level->image + offset, 1, level->centered + template, 1, &part, count);
        correlation += part;
        vDSP_dotpr(level->image + offset, 1, level->weights + template, 1, &part, count);
        sum += part;
        vDSP_dotpr(level->squared + offset, 1, level->weights + template, 1, &part, count);
        square += part;
    }
    float variance = square - sum * sum / level->weightSum;
    if (variance <= SWFlat(level->weightSum) || level->variance <= 0) {
        return 0;
    }
    return correlation / sqrtf(level->variance * variance);
}

static NSArray<SWMatchLevel *> *SWBuildLevels(SWPlane *base, SWRaster *template, SWPlane *gray, SWKernel *full, SWCancelToken *token, NSError **error) {
    NSInteger depth = 0;
    while (depth < SWDeepestLevel && MIN(template.width, template.height) >> (depth + 1) >= SWCoarsestSide) {
        depth++;
    }
    NSMutableArray<SWMatchLevel *> *levels = [NSMutableArray arrayWithObject:[[SWMatchLevel alloc] initWithImage:base kernel:full]];
    for (NSInteger level = 1; level <= depth; level++) {
        if ([token failIfCancelled:error]) {
            return nil;
        }
        SWPlane *image = [base scaledToWidth:MAX(base.width >> level, 1) height:MAX(base.height >> level, 1) error:error];
        if (image == nil) {
            return nil;
        }
        NSInteger width = MAX(template.width >> level, 1);
        NSInteger height = MAX(template.height >> level, 1);
        if (width > image.width || height > image.height) {
            break;
        }
        SWPlane *values = [gray scaledToWidth:width height:height error:error];
        SWPlane *weights = values == nil ? nil : [full.weights scaledToWidth:width height:height error:error];
        SWKernel *kernel = weights == nil ? nil : [[SWKernel alloc] initWithValues:values weights:weights error:error];
        if (kernel == nil) {
            return nil;
        }
        [levels addObject:[[SWMatchLevel alloc] initWithImage:image kernel:kernel]];
    }
    return levels;
}

static NSInteger SWCoarseCandidates(const SWLevelView *coarse, float cutoff, NSInteger wanted, SWPosition *kept) {
    NSInteger rows = coarse->imageHeight - coarse->height + 1;
    NSInteger columns = coarse->imageWidth - coarse->width + 1;
    float *correlation = SWCorrelate(coarse->image, coarse->imageWidth, coarse->imageHeight, coarse->centered, coarse->width, coarse->height);
    float *sums = SWCorrelate(coarse->image, coarse->imageWidth, coarse->imageHeight, coarse->weights, coarse->width, coarse->height);
    float *squaredSums = SWCorrelate(coarse->squared, coarse->imageWidth, coarse->imageHeight, coarse->weights, coarse->width, coarse->height);
    float minimum = SWFlat(coarse->weightSum);
    NSInteger capacity = 256;
    NSInteger count = 0;
    SWCandidate *candidates = malloc(capacity * sizeof(SWCandidate));
    for (NSInteger y = 0; y < rows; y++) {
        for (NSInteger x = 0; x < columns; x++) {
            NSInteger index = y * coarse->imageWidth + x;
            float variance = squaredSums[index] - sums[index] * sums[index] / coarse->weightSum;
            if (variance <= minimum) {
                continue;
            }
            float value = correlation[index] / sqrtf(coarse->variance * variance);
            if (value >= cutoff) {
                if (count == capacity) {
                    capacity *= 2;
                    candidates = realloc(candidates, capacity * sizeof(SWCandidate));
                }
                candidates[count++] = (SWCandidate){.score = value, .x = x, .y = y};
            }
        }
    }
    free(correlation);
    free(sums);
    free(squaredSums);
    if (count > 1) {
        mergesort_b(candidates, count, sizeof(SWCandidate), ^int(const void *a, const void *b) {
            float first = ((const SWCandidate *)a)->score;
            float second = ((const SWCandidate *)b)->score;
            return first > second ? -1 : first < second;
        });
    }
    NSInteger keptCount = 0;
    for (NSInteger index = 0; index < count && keptCount < wanted; index++) {
        SWCandidate candidate = candidates[index];
        BOOL close = NO;
        for (NSInteger other = 0; other < keptCount && !close; other++) {
            close = labs(kept[other].x - candidate.x) * 2 < coarse->width && labs(kept[other].y - candidate.y) * 2 < coarse->height;
        }
        if (!close) {
            kept[keptCount++] = (SWPosition){.x = candidate.x, .y = candidate.y};
        }
    }
    free(candidates);
    return keptCount;
}

static void SWRefinePosition(const SWLevelView *views, NSInteger levelCount, NSInteger *x, NSInteger *y, float *best) {
    for (NSInteger level = levelCount - 2; level >= 0; level--) {
        const SWLevelView *current = &views[level];
        NSInteger limitX = current->imageWidth - current->width;
        NSInteger limitY = current->imageHeight - current->height;
        NSInteger centerX = *x * 2;
        NSInteger centerY = *y * 2;
        *best = -2;
        for (NSInteger dy = -SWRefineRadius; dy <= SWRefineRadius; dy++) {
            for (NSInteger dx = -SWRefineRadius; dx <= SWRefineRadius; dx++) {
                NSInteger px = MIN(MAX(centerX + dx, 0), limitX);
                NSInteger py = MIN(MAX(centerY + dy, 0), limitY);
                float value = SWScore(current, px, py);
                if (value > *best) {
                    *best = value;
                    *x = px;
                    *y = py;
                }
            }
        }
    }
}

static NSArray<SWMatch *> *SWRefineCandidates(const SWLevelView *views, NSInteger levelCount, const SWPosition *kept, NSInteger keptCount, SWRaster *target, SWRaster *template, SWPlane *alpha, float threshold, double factor, SWCancelToken *token, NSError **error) {
    SWColorKernel *colors = nil;
    if (!target.isGray && !template.isGray) {
        colors = [[SWColorKernel alloc] initWithTemplate:template alpha:alpha error:error];
        if (colors == nil) {
            return nil;
        }
    }
    NSMutableArray<SWMatch *> *matches = [NSMutableArray array];
    for (NSInteger index = 0; index < keptCount; index++) {
        if ([token failIfCancelled:error]) {
            return nil;
        }
        NSInteger x = kept[index].x;
        NSInteger y = kept[index].y;
        float best = 0;
        SWRefinePosition(views, levelCount, &x, &y, &best);
        if (levelCount == 1) {
            best = SWScore(&views[0], x, y);
        }
        float result = colors == nil ? best : [colors scoreIn:target x:x y:y];
        if (result >= threshold) {
            [matches addObject:[[SWMatch alloc] initWithRect:CGRectMake(x, y, template.width, template.height) score:result scale:factor]];
        }
    }
    return matches;
}

static NSArray<SWMatch *> *SWSearch(SWPlane *base, SWRaster *target, SWRaster *template, float threshold, NSInteger limit, double factor, SWCancelToken *token, NSError **error) {
    SWPlane *gray = [[SWPlane alloc] initWithRaster:template error:error];
    if (gray == nil) {
        return nil;
    }
    SWPlane *alpha = SWTemplateWeights(template, error);
    if (alpha == nil) {
        return nil;
    }
    SWKernel *full = [[SWKernel alloc] initWithValues:gray weights:alpha error:error];
    if (full == nil) {
        return nil;
    }
    if (full.variance / full.weightSum <= 1e-6f) {
        SWFail(error, SWErrorNameRange, @"the template has no contrast to match");
        return nil;
    }
    NS_VALID_UNTIL_END_OF_SCOPE NSArray<SWMatchLevel *> *levels = SWBuildLevels(base, template, gray, full, token, error);
    if (levels == nil) {
        return nil;
    }
    NSInteger levelCount = (NSInteger)levels.count;
    SWLevelView views[SWDeepestLevel + 1];
    for (NSInteger index = 0; index < levelCount; index++) {
        views[index] = SWViewOf(levels[index]);
    }
    const SWLevelView *coarse = &views[levelCount - 1];
    if (coarse->imageHeight - coarse->height + 1 <= 0 || coarse->imageWidth - coarse->width + 1 <= 0) {
        return @[];
    }
    if ([token failIfCancelled:error]) {
        return nil;
    }
    NSInteger wanted = MIN(MAX(limit * 3, 20), 300);
    SWPosition *kept = malloc(wanted * sizeof(SWPosition));
    float cutoff = MAX(threshold - (levelCount > 1 ? 0.25f : 0.1f), 0.f);
    NSInteger keptCount = SWCoarseCandidates(coarse, cutoff, wanted, kept);
    NSArray<SWMatch *> *matches = nil;
    if (![token failIfCancelled:error]) {
        matches = SWRefineCandidates(views, levelCount, kept, keptCount, target, template, alpha, threshold, factor, token, error);
    }
    free(kept);
    return matches;
}

static double SWIntersectionOverUnion(CGRect a, CGRect b) {
    CGRect overlap = CGRectIntersection(a, b);
    if (CGRectIsNull(overlap)) {
        return 0;
    }
    double shared = CGRectGetWidth(overlap) * CGRectGetHeight(overlap);
    return shared / (CGRectGetWidth(a) * CGRectGetHeight(a) + CGRectGetWidth(b) * CGRectGetHeight(b) - shared);
}

NSArray<SWMatch *> *SWTemplateMatchingFind(SWRaster *target, SWRaster *template, NSArray<NSNumber *> *factors, double threshold, NSInteger limit, double overlap, SWCancelToken *token, NSError **error) {
    SWPlane *base = [[SWPlane alloc] initWithRaster:target error:error];
    if (base == nil) {
        return nil;
    }
    NSMutableArray<SWMatch *> *found = [NSMutableArray array];
    for (NSNumber *factor in factors) {
        NSInteger width = (NSInteger)round(template.width * factor.doubleValue);
        NSInteger height = (NSInteger)round(template.height * factor.doubleValue);
        if (width < 3 || height < 3 || width > target.width || height > target.height) {
            continue;
        }
        SWRaster *resized = SWRasterResized(template, width, height, error);
        if (resized == nil) {
            return nil;
        }
        NSArray<SWMatch *> *matches = SWSearch(base, target, resized, (float)threshold, limit, factor.doubleValue, token, error);
        if (matches == nil) {
            return nil;
        }
        [found addObjectsFromArray:matches];
    }
    NSArray<SWMatch *> *sorted = [found sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(SWMatch *first, SWMatch *second) {
        if (first.score == second.score) {
            return NSOrderedSame;
        }
        return first.score > second.score ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray<SWMatch *> *kept = [NSMutableArray array];
    for (SWMatch *match in sorted) {
        if ((NSInteger)kept.count >= limit) {
            break;
        }
        BOOL overlapping = NO;
        for (SWMatch *other in kept) {
            if (SWIntersectionOverUnion(other.rect, match.rect) > overlap) {
                overlapping = YES;
                break;
            }
        }
        if (!overlapping) {
            [kept addObject:match];
        }
    }
    return kept;
}
