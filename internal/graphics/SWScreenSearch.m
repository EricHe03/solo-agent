//go:build darwin && cgo

#import "SWScreenSearch.h"

#import "SWArguments.h"
#import "SWCall.h"
#import "SWCancelToken.h"
#import "SWError.h"
#import "SWGoBridge.h"
#import "SWImageNode.h"
#import "SWJSON.h"
#import "SWRaster.h"
#import "SWRecognition.h"
#import "SWScreenComparison.h"
#import "SWTemplateMatching.h"

@implementation SWScreenHit

- (instancetype)initWithFrame:(CGRect)frame score:(double)score text:(NSString *)text target:(NSInteger)target {
    self = [super init];
    if (self) {
        _frame = frame;
        _score = score;
        _text = text;
        _target = target;
    }
    return self;
}

@end

static NSArray *SWScreenTargets(SWCall *call, NSUInteger first, NSError **error) {
    NSMutableArray *targets = [NSMutableArray array];
    NSUInteger images = first;
    for (NSDictionary *entry in [call.arguments objects:@"targets"]) {
        if ([entry[@"kind"] isEqual:@"text"]) {
            NSString *pattern = entry[@"pattern"];
            if (![pattern isKindOfClass:NSString.class]) {
                SWFail(error, SWErrorNameType, @"graphics: a text target needs a pattern");
                return nil;
            }
            NSString *flags = [entry[@"flags"] isKindOfClass:NSString.class] ? entry[@"flags"] : @"";
            NSRegularExpressionOptions options = [flags containsString:@"i"] ? NSRegularExpressionCaseInsensitive : 0;
            NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:error];
            if (expression == nil) {
                return nil;
            }
            [targets addObject:expression];
        } else {
            SWImageNode *image = [call image:images error:error];
            if (image == nil) {
                return nil;
            }
            [targets addObject:image];
            images += 1;
        }
    }
    if (targets.count == 0) {
        SWFail(error, SWErrorNameType, @"graphics: find needs a target");
        return nil;
    }
    return targets;
}

@implementation SWScreenSearch {
    NSArray *_targets;
    SWArguments *_arguments;
    SWCancelToken *_token;
    SWCallContext *_context;
    SWScreenComparison *_comparison;
    SWRaster *_previous;
    SWRaster *_probed;
    BOOL _hasProbedAt;
    double _probedAt;
    BOOL _resting;
    NSInteger _frames;
    NSInteger _probes;
    double _probing;
    double _comparing;
    double _last;
}

- (instancetype)initWithCall:(SWCall *)call firstObject:(NSUInteger)first error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _targets = SWScreenTargets(call, first, error);
    if (_targets == nil) {
        return nil;
    }
    _arguments = call.arguments;
    _token = call.token;
    _context = call.context;
    _resting = YES;
    return self;
}

- (SWRecognizedText *)recognize:(SWImageNode *)node error:(NSError **)error {
    NSMutableDictionary *values = [@{@"level": @"accurate", @"correction": @NO} mutableCopy];
    for (NSString *key in @[@"region", @"languages", @"minimumHeight"]) {
        id value = _arguments.values[key];
        if (value != nil) {
            values[key] = value;
        }
    }
    return SWRecognizeText(node, [[SWArguments alloc] initWithValues:values], _token, error);
}

- (SWScreenHit *)matchText:(NSRegularExpression *)expression in:(SWRecognizedText *)recognized target:(NSInteger)target {
    for (NSUInteger line = 0; line < recognized.lines.count; line++) {
        NSDictionary *entry = recognized.lines[line];
        NSString *text = entry[@"text"];
        if (![text isKindOfClass:NSString.class]) {
            continue;
        }
        NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (match == nil) {
            continue;
        }
        NSDictionary *box = [recognized boundingBoxLine:(NSInteger)line candidate:0 start:(NSInteger)match.range.location end:(NSInteger)NSMaxRange(match.range) error:nil];
        NSArray<NSNumber *> *numbers = (box ?: entry)[@"frame"];
        if (![numbers isKindOfClass:NSArray.class] || numbers.count != 4) {
            continue;
        }
        CGRect frame = CGRectMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue);
        return [[SWScreenHit alloc] initWithFrame:frame score:SWAsNumber(entry[@"confidence"]).doubleValue text:[text substringWithRange:match.range] target:target];
    }
    return nil;
}

- (SWScreenHit *)probe:(SWImageNode *)node error:(NSError **)error {
    CGRect region;
    BOOL hasRegion = [_arguments rect:@"region" into:&region];
    CGPoint origin = CGPointZero;
    SWRaster *target = [node rasterInSpace:hasRegion ? &region : NULL origin:&origin token:_token error:error];
    if (target == nil) {
        return nil;
    }
    double threshold = [_arguments double:@"threshold" fallback:0.8];
    NSNumber *binarize = [_arguments number:@"binarize"];
    SWRaster *binaryTarget = nil;
    SWRecognizedText *recognized = nil;
    for (NSUInteger index = 0; index < _targets.count; index++) {
        if ([_token failIfCancelled:error]) {
            return nil;
        }
        id entry = _targets[index];
        if ([entry isKindOfClass:NSRegularExpression.class]) {
            recognized = recognized ?: [self recognize:node error:error];
            if (recognized == nil) {
                return nil;
            }
            SWScreenHit *hit = [self matchText:entry in:recognized target:(NSInteger)index];
            if (hit != nil) {
                return hit;
            }
            continue;
        }
        SWImageNode *template = entry;
        double base = node.scale / template.scale;
        NSMutableArray<NSNumber *> *factors = [NSMutableArray array];
        for (NSNumber *scale in [_arguments numbers:@"scales"] ?: @[@1]) {
            [factors addObject:@(scale.doubleValue * base)];
        }
        SWRaster *searched = target;
        SWRaster *pattern = [template raster:_token error:error];
        if (pattern == nil) {
            return nil;
        }
        if (binarize != nil) {
            if (binaryTarget == nil) {
                SWRaster *gray = SWRasterGrayscale(target, error);
                binaryTarget = gray == nil ? nil : SWRasterThresholded(gray, binarize.integerValue, error);
                if (binaryTarget == nil) {
                    return nil;
                }
            }
            searched = binaryTarget;
            SWRaster *gray = SWRasterGrayscale(pattern, error);
            pattern = gray == nil ? nil : SWRasterThresholded(gray, binarize.integerValue, error);
            if (pattern == nil) {
                return nil;
            }
        }
        NSArray<SWMatch *> *matches = SWTemplateMatchingFind(searched, pattern, factors, threshold, 1, 0.3, _token, error);
        if (matches == nil) {
            return nil;
        }
        SWMatch *match = matches.firstObject;
        if (match != nil) {
            return [[SWScreenHit alloc] initWithFrame:[node spaceRect:CGRectOffset(match.rect, origin.x, origin.y)] score:match.score text:nil target:(NSInteger)index];
        }
    }
    return nil;
}

- (SWScreenHit *)check:(SWImageNode *)node error:(NSError **)error {
    if (_comparison == nil) {
        CGRect region;
        BOOL hasRegion = [_arguments rect:@"region" into:&region];
        _comparison = [[SWScreenComparison alloc] initWithNode:node region:hasRegion ? &region : NULL threshold:SWDefaultDifferenceThreshold error:error];
        if (_comparison == nil) {
            return nil;
        }
    }
    _frames += 1;
    double compared = SWNowMilliseconds();
    SWRaster *plane = [_comparison plane:node token:_token error:error];
    if (plane == nil) {
        return nil;
    }
    BOOL fresh = YES;
    if (_probed != nil && ![_comparison changed:_probed from:plane result:&fresh error:error]) {
        return nil;
    }
    BOOL settled = YES;
    if (fresh && _previous != nil) {
        BOOL moved = NO;
        if (![_comparison changed:_previous from:plane result:&moved error:error]) {
            return nil;
        }
        settled = !moved;
    }
    _previous = plane;
    _comparing += SWNowMilliseconds() - compared;
    if (!fresh) {
        _resting = YES;
        return nil;
    }
    double time = !isnan(node.time) ? node.time : !isnan(node.timestamp) ? node.timestamp : SWNowMilliseconds();
    BOOL due = !_hasProbedAt || time - _probedAt >= 2 * _last;
    BOOL rested = _resting;
    _resting = NO;
    if (!settled && !rested && !due) {
        return nil;
    }
    _probed = plane;
    _hasProbedAt = YES;
    _probedAt = time;
    double started = SWNowMilliseconds();
    SWScreenHit *hit = [self probe:node error:error];
    _last = SWNowMilliseconds() - started;
    _probing += _last;
    _probes += 1;
    return hit;
}

- (NSString *)describeTargets {
    NSMutableArray<NSString *> *described = [NSMutableArray array];
    for (id target in _targets) {
        if ([target isKindOfClass:NSRegularExpression.class]) {
            [described addObject:[NSString stringWithFormat:@"text /%@/", ((NSRegularExpression *)target).pattern]];
        } else {
            SWImageNode *image = target;
            [described addObject:[NSString stringWithFormat:@"image %ldx%ld", (long)image.pixelWidth, (long)image.pixelHeight]];
        }
    }
    return [described componentsJoinedByString:@", "];
}

- (void)traceName:(NSString *)name started:(double)started hit:(SWScreenHit *)hit frameTime:(double)frameTime {
    if (!_context.tracing) {
        return;
    }
    double now = SWNowMilliseconds();
    NSString *where = @"the screen";
    CGRect region;
    if ([_arguments rect:@"region" into:&region]) {
        where = [NSString stringWithFormat:@"[%ld, %ld, %ld, %ld]", (long)SWRectJSON(region)[0].doubleValue, (long)SWRectJSON(region)[1].doubleValue, (long)SWRectJSON(region)[2].doubleValue, (long)SWRectJSON(region)[3].doubleValue];
    }
    NSString *result = hit == nil ? @"no match" : [NSString stringWithFormat:@"matched target %ld", (long)hit.target];
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%@ in %@, %@; compared %ld frames in %ld ms, probed %ld in %ld ms, last %ld ms",
                                                               [self describeTargets], where, result, (long)_frames, (long)_comparing, (long)_probes, (long)_probing, (long)_last];
    if (hit != nil && !isnan(frameTime)) {
        [detail appendFormat:@", the matched frame is %ld ms old", (long)(now - frameTime)];
    }
    [_context traceName:name detail:detail started:started duration:now - started];
}

@end
