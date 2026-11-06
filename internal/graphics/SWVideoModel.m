//go:build darwin && cgo

#import "SWVideoModel.h"

#import "SWCancelToken.h"
#import "SWChangeTracker.h"
#import "SWError.h"
#import "SWImageNode.h"
#import "SWJSON.h"
#import "SWRaster.h"
#import "SWSegmentReader.h"

@implementation SWVideoSegment

- (instancetype)initWithURL:(NSURL *)url start:(double)start duration:(double)duration turns:(NSInteger)turns {
    self = [super init];
    if (self) {
        _url = url;
        _start = start;
        _duration = duration;
        _turns = turns;
    }
    return self;
}

@end

@implementation SWVideoModel {
    double _clockOffset;
    SWScreenGeometry _screen;
    NSArray<SWVideoSegment *> *_segments;
    NSArray<NSDictionary *> *_events;
    NSLock *_lock;
    NSMutableDictionary<NSNumber *, SWSegmentReader *> *_readers;
}

- (instancetype)initWithURL:(NSURL *)url metadata:(NSDictionary *)metadata error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _url = url;
    NSNumber *start = SWAsNumber(metadata[@"start"]);
    _start = start == nil ? NAN : start.doubleValue;
    _duration = SWAsNumber(metadata[@"duration"]).doubleValue;
    NSNumber *scale = SWAsNumber(metadata[@"scale"]);
    _scale = scale == nil ? 1 : scale.doubleValue;
    _clockOffset = SWAsNumber(metadata[@"clockOffset"]).doubleValue;
    NSDictionary *screen = [metadata[@"screen"] isKindOfClass:NSDictionary.class] ? metadata[@"screen"] : @{};
    _screen = (SWScreenGeometry){.width = SWAsNumber(screen[@"width"]).integerValue, .height = SWAsNumber(screen[@"height"]).integerValue, .scale = _scale};
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSMutableArray<SWVideoSegment *> *segments = [NSMutableArray array];
    NSArray *listed = [metadata[@"segments"] isKindOfClass:NSArray.class] ? metadata[@"segments"] : @[];
    for (NSDictionary *segment in listed) {
        if (![segment isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *file = segment[@"file"];
        if (![file isKindOfClass:NSString.class] || file.length == 0 || [file isEqualToString:@"."] || [file isEqualToString:@".."] || [file containsString:@"/"]) {
            continue;
        }
        [segments addObject:[[SWVideoSegment alloc] initWithURL:[directory URLByAppendingPathComponent:file] start:SWAsNumber(segment[@"start"]).doubleValue
                                                       duration:SWAsNumber(segment[@"duration"]).doubleValue turns:SWAsNumber(segment[@"turns"]).integerValue]];
    }
    if (segments.count == 0) {
        SWFail(error, SWErrorNameData, @"graphics: the recording lists no video");
        return nil;
    }
    _segments = segments;
    _changes = [metadata[@"changes"] isKindOfClass:NSArray.class] ? metadata[@"changes"] : @[];
    _events = [metadata[@"events"] isKindOfClass:NSArray.class] ? metadata[@"events"] : @[];
    _lock = [NSLock new];
    _readers = [NSMutableDictionary dictionary];
    return self;
}

- (NSInteger)segmentIndexAt:(double)time {
    NSInteger found = 0;
    for (NSUInteger index = 0; index < _segments.count; index++) {
        if (_segments[index].start <= time) {
            found = (NSInteger)index;
        }
    }
    return found;
}

- (void)pixelSizeAt:(double)time width:(NSInteger *)width height:(NSInteger *)height {
    SWVideoSegment *segment = _segments[[self segmentIndexAt:time - _clockOffset]];
    *width = segment.turns % 2 == 0 ? _screen.width : _screen.height;
    *height = segment.turns % 2 == 0 ? _screen.height : _screen.width;
}

- (SWSegmentReader *)reader:(NSInteger)index error:(NSError **)error {
    [_lock lock];
    SWSegmentReader *reader = _readers[@(index)];
    if (reader == nil) {
        reader = [[SWSegmentReader alloc] initWithURL:_segments[index].url error:error];
        if (reader != nil) {
            _readers[@(index)] = reader;
        }
    }
    [_lock unlock];
    return reader;
}

- (SWRaster *)rasterAt:(double)time token:(SWCancelToken *)token error:(NSError **)error {
    double stored = time - _clockOffset;
    NSInteger index = [self segmentIndexAt:stored];
    SWVideoSegment *segment = _segments[index];
    SWSegmentReader *reader = [self reader:index error:error];
    if (reader == nil || [token failIfCancelled:error]) {
        return nil;
    }
    SWDecodedBuffer *decoded = [reader frameAt:MAX(stored - segment.start, 0) / 1000 error:error];
    if (decoded == nil) {
        return nil;
    }
    return [[[SWFrame alloc] initWithPixelBuffer:decoded.buffer time:time turns:segment.turns geometry:_screen] raster:error];
}

- (BOOL)scanFrom:(double)from to:(double)to token:(SWCancelToken *)token error:(NSError **)error visitor:(BOOL (^)(SWFrame *, BOOL *, NSError **))visitor {
    double first = from - _clockOffset;
    double last = to - _clockOffset;
    for (NSUInteger index = 0; index < _segments.count; index++) {
        SWVideoSegment *segment = _segments[index];
        if (segment.start + segment.duration < first || segment.start > last) {
            continue;
        }
        SWSegmentReader *reader = [self reader:(NSInteger)index error:error];
        if (reader == nil) {
            return NO;
        }
        double start = MAX(first - segment.start, 0) / 1000;
        double end = (MIN(last, segment.start + segment.duration) - segment.start) / 1000;
        BOOL going = YES;
        double clockOffset = _clockOffset;
        SWScreenGeometry screen = _screen;
        BOOL scanned = [reader eachFrom:start through:end token:token going:&going error:error visitor:^BOOL(double seconds, CVPixelBufferRef buffer, BOOL *keepGoing, NSError **failure) {
            SWFrame *frame = [[SWFrame alloc] initWithPixelBuffer:buffer time:segment.start + seconds * 1000 + clockOffset turns:segment.turns geometry:screen];
            return visitor(frame, keepGoing, failure);
        }];
        if (!scanned) {
            return NO;
        }
        if (!going) {
            return YES;
        }
    }
    return YES;
}

- (NSString *)info {
    NSInteger width = 0;
    NSInteger height = 0;
    [self pixelSizeAt:0 width:&width height:&height];
    NSDictionary *object = @{
        @"path": _url.path, @"start": isnan(_start) ? NSNull.null : @(_start), @"duration": @(SWRounded(_duration)),
        @"width": @(SWRounded(width / _scale)), @"height": @(SWRounded(height / _scale)),
        @"scale": @(_scale), @"changes": _changes, @"events": _events,
    };
    return SWEncodeJSON(object) ?: @"{}";
}

- (SWImageNode *)nodeAt:(double)time {
    return [SWImageNode nodeWithVideo:self time:MIN(MAX(time, 0), _duration)];
}

- (NSArray<NSNumber *> *)defaultGridTimes {
    NSMutableArray<NSNumber *> *changed = [NSMutableArray arrayWithObject:@0];
    for (NSDictionary *change in _changes) {
        NSNumber *after = [change isKindOfClass:NSDictionary.class] ? SWAsNumber(change[@"after"]) : nil;
        if (after != nil) {
            [changed addObject:after];
        }
    }
    NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    if (changed.count > 1) {
        double step = MAX((double)changed.count / 16, 1);
        for (double position = 0; position < changed.count; position += step) {
            [times addObject:changed[(NSUInteger)position]];
        }
        return times;
    }
    for (NSInteger index = 0; index < 12; index++) {
        [times addObject:@(_duration * index / 12)];
    }
    return times;
}

@end

NSURL *SWVideoSidecar(NSURL *url) {
    return [url.URLByDeletingPathExtension URLByAppendingPathExtension:@"json"];
}

AVAssetTrack *SWVideoFirstTrack(AVURLAsset *asset, NSError **error) {
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    __block NSArray<AVAssetTrack *> *tracks = nil;
    __block NSError *failure = nil;
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *found, NSError *loadError) {
        tracks = found;
        failure = loadError;
        dispatch_semaphore_signal(loaded);
    }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (failure != nil) {
        SWFailWith(error, failure);
        return nil;
    }
    if (tracks.firstObject == nil) {
        SWFail(error, SWErrorNameData, @"graphics: %@ has no video track", asset.URL.lastPathComponent);
    }
    return tracks.firstObject;
}

NSDictionary *SWVideoChangeJSON(SWChange *change, double factor, double scale, NSString *app) {
    NSUInteger count = change.regions.length / sizeof(CGRect);
    const CGRect *regions = change.regions.bytes;
    NSMutableArray *frames = [NSMutableArray array];
    for (NSUInteger index = 0; index < count; index++) {
        CGRect region = regions[index];
        [frames addObject:SWRectJSON(CGRectMake(CGRectGetMinX(region) * factor / scale, CGRectGetMinY(region) * factor / scale, CGRectGetWidth(region) * factor / scale, CGRectGetHeight(region) * factor / scale))];
    }
    return @{
        @"time": @(SWRounded(change.start)), @"end": @(SWRounded(change.after)), @"before": @(SWRounded(change.before)), @"after": @(SWRounded(change.after)),
        @"frames": frames, @"app": app ?: NSNull.null,
    };
}

SWVideoModel *SWVideoOpen(NSURL *url, SWCancelToken *token, NSError **error) {
    NSData *data = [NSData dataWithContentsOfURL:SWVideoSidecar(url)];
    NSDictionary *metadata = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([metadata isKindOfClass:NSDictionary.class]) {
        return [[SWVideoModel alloc] initWithURL:url metadata:metadata error:error];
    }
    return SWVideoAnalyze(url, token, error);
}
