//go:build darwin && cgo

#import "SWRecordingSession.h"

#import <CoreMedia/CoreMedia.h>

#import "SWAccessUnit.h"
#import "SWCancelToken.h"
#import "SWChangeTracker.h"
#import "SWError.h"
#import "SWFrame.h"
#import "SWGoBridge.h"
#import "SWHEVC.h"
#import "SWJSON.h"
#import "SWRaster.h"
#import "SWScreenFeed.h"
#import "SWSegmentWriter.h"
#import "SWVideoModel.h"

static const double SWKeyFrameInterval = 2;
static const double SWFeedInterval = 250;
static const NSInteger SWClockDeltaLimit = 8192;

@interface SWRecordingSegment : NSObject
@property (nonatomic, readonly) NSString *file;
@property (nonatomic, readonly) double start;
@property (nonatomic, readonly) NSInteger turns;
@property (nonatomic, readonly) SWSegmentWriter *writer;
@end

@implementation SWRecordingSegment

- (instancetype)initWithFile:(NSString *)file start:(double)start turns:(NSInteger)turns writer:(SWSegmentWriter *)writer {
    self = [super init];
    if (self) {
        _file = file;
        _start = start;
        _turns = turns;
        _writer = writer;
    }
    return self;
}

@end

typedef struct {
    BOOL active;
    double start;
    NSInteger frames;
    double decoded;
} SWFeedWindow;

static NSDictionary *SWFeedEvent(SWFeedWindow window) {
    return @{@"time": @(window.start), @"type": @"feed", @"frames": @(window.frames), @"decodedMs": @(SWRounded(window.decoded))};
}

@implementation SWRecordingSession {
    SWScreenGeometry _geometry;
    NSLock *_lock;
    dispatch_queue_t _tracking;
    SWChangeTracker *_tracker;
    dispatch_group_t _finishing;
    dispatch_semaphore_t _began;
    SWTimelineWatch *_timeline;
    NSArray<NSNumber *> *_listeners;
    dispatch_source_t _timer;
    BOOL _hasOrigin;
    double _origin;
    double _last;
    NSMutableArray<SWRecordingSegment *> *_segments;
    SWSegmentWriter *_writer;
    CMVideoFormatDescriptionRef _format;
    BOOL _waiting;
    BOOL _stopped;
    NSMutableArray<NSString *> *_failures;
    SWFrame *_queued;
    BOOL _busy;
    double *_clockDeltas;
    NSInteger _clockDeltaCount;
    SWFeedWindow _window;
    NSMutableArray<NSDictionary *> *_feed;
}

- (instancetype)initWithURL:(NSURL *)url geometry:(SWScreenGeometry)geometry timeline:(SWTimelineWatch *)timeline {
    self = [super init];
    if (self) {
        _url = url;
        _geometry = geometry;
        _timeline = timeline;
        _lock = [NSLock new];
        _tracking = dispatch_queue_create("io.nekohasekai.swipt.graphics.recording", DISPATCH_QUEUE_SERIAL);
        _tracker = [SWChangeTracker new];
        _finishing = dispatch_group_create();
        _began = dispatch_semaphore_create(0);
        _segments = [NSMutableArray array];
        _waiting = YES;
        _failures = [NSMutableArray array];
        _clockDeltas = malloc((SWClockDeltaLimit + 1) * sizeof(double));
        _feed = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    free(_clockDeltas);
    if (_format != NULL) {
        CFRelease(_format);
    }
}

- (double)start {
    [_lock lock];
    double origin = _origin;
    [_lock unlock];
    return origin;
}

+ (instancetype)startWithURL:(NSURL *)url timeline:(SWTimelineWatch *)timeline token:(SWCancelToken *)token error:(NSError **)error {
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    [NSFileManager.defaultManager removeItemAtURL:SWVideoSidecar(url) error:nil];
    SWScreenFeed *feed = SWScreenFeed.shared;
    SWScreenGeometry geometry;
    if (![feed acquire:&geometry error:error]) {
        return nil;
    }
    SWRecordingSession *session = [[self alloc] initWithURL:url geometry:geometry timeline:timeline];
    session->_listeners = @[
        @([feed addUnitListener:^(SWAccessUnit *unit) {
            [session append:unit];
        }]),
        @([feed addFrameListener:^(SWFrame *frame) {
            [session observe:frame];
        }]),
    ];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, session->_tracking);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SWKeyFrameInterval * NSEC_PER_SEC)), (uint64_t)(SWKeyFrameInterval * NSEC_PER_SEC), 0);
    dispatch_source_set_event_handler(timer, ^{
        [SWScreenFeed.shared requestKeyFrame];
        [session tick];
    });
    dispatch_resume(timer);
    session->_timer = timer;
    [feed requestKeyFrame];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:SWScreenFirstFrameLimit];
    while (dispatch_semaphore_wait(session->_began, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
        NSError *failure = nil;
        if (![token failIfCancelled:&failure] && [deadline timeIntervalSinceNow] <= 0) {
            failure = SWMakeError(SWErrorNameUnavailable, [NSString stringWithFormat:@"graphics: the screen sent no frame within %ld s; it may be off", (long)SWScreenFirstFrameLimit]);
        }
        if (failure != nil) {
            [session stop:nil error:nil];
            SWFailWith(error, failure);
            return nil;
        }
    }
    return session;
}

- (void)append:(SWAccessUnit *)unit {
    [_lock lock];
    [self appendLocked:unit];
    [_lock unlock];
}

- (void)appendLocked:(SWAccessUnit *)unit {
    if (_stopped) {
        return;
    }
    if (unit.damaged) {
        _waiting = YES;
        return;
    }
    if (unit.hasParameterSets) {
        CMVideoFormatDescriptionRef described = SWHEVCFormat(unit.nals);
        if (described != NULL) {
            if (_format != NULL) {
                CFRelease(_format);
            }
            _format = described;
        }
    }
    BOOL changed = YES;
    if (_writer != nil && _format != NULL) {
        changed = _writer.turns != unit.turns || !CMFormatDescriptionEqual(_format, _writer.format);
    }
    if (changed) {
        if (_writer != nil) {
            [self closeWriter:_writer];
            _writer = nil;
        }
        if (!unit.isKeyframe || _format == NULL) {
            _waiting = YES;
            return;
        }
        if (!_hasOrigin) {
            _hasOrigin = YES;
            _origin = unit.arrival;
            dispatch_semaphore_signal(_began);
        }
        NSUInteger index = _segments.count;
        NSString *base = _url.URLByDeletingPathExtension.lastPathComponent;
        NSString *file = index == 0 ? _url.lastPathComponent : [NSString stringWithFormat:@"%@-%lu.%@", base, (unsigned long)index + 1, _url.pathExtension];
        NSURL *target = [_url.URLByDeletingLastPathComponent URLByAppendingPathComponent:file];
        NSError *failure = nil;
        SWSegmentWriter *created = [[SWSegmentWriter alloc] initWithURL:target format:_format turns:unit.turns error:&failure];
        if (created == nil) {
            [_failures addObject:SWErrorMessageOf(failure)];
            return;
        }
        _writer = created;
        [_segments addObject:[[SWRecordingSegment alloc] initWithFile:file start:unit.arrival - _origin turns:unit.turns writer:created]];
        _waiting = NO;
    }
    if (_waiting) {
        if (!unit.isKeyframe) {
            return;
        }
        _waiting = NO;
    }
    if (_writer != nil && _hasOrigin && _segments.lastObject != nil) {
        double stored = _segments.lastObject.start + CMTimeGetSeconds([_writer append:unit]) * 1000;
        _clockDeltas[_clockDeltaCount++] = unit.arrival - _origin - stored;
        if (_clockDeltaCount > SWClockDeltaLimit) {
            NSInteger kept = 0;
            for (NSInteger index = 0; index < _clockDeltaCount; index += 2) {
                _clockDeltas[kept++] = _clockDeltas[index];
            }
            _clockDeltaCount = kept;
        }
    }
    _last = unit.arrival;
}

- (void)closeWriter:(SWSegmentWriter *)writer {
    dispatch_group_enter(_finishing);
    [writer finish:^(NSString *failure) {
        if (failure != nil) {
            [self->_lock lock];
            [self->_failures addObject:failure];
            [self->_lock unlock];
        }
        dispatch_group_leave(self->_finishing);
    }];
}

- (void)observe:(SWFrame *)frame {
    [_lock lock];
    if (_stopped || !_hasOrigin || frame.time < _origin) {
        [_lock unlock];
        return;
    }
    if (_window.active && frame.time >= _window.start + SWFeedInterval) {
        [_feed addObject:SWFeedEvent(_window)];
        _window.active = NO;
    }
    if (!_window.active) {
        _window = (SWFeedWindow){.active = YES, .start = frame.time};
    }
    _window.frames += 1;
    _window.decoded = MAX(_window.decoded, SWNowMilliseconds() - frame.time);
    _queued = frame;
    BOOL start = !_busy;
    _busy = YES;
    [_lock unlock];
    if (start) {
        dispatch_async(_tracking, ^{
            [self drain];
        });
    }
}

- (void)drain {
    while (YES) {
        @autoreleasepool {
            [_lock lock];
            SWFrame *frame = _queued;
            double origin = _origin;
            if (frame == nil || !_hasOrigin) {
                _busy = NO;
                [_lock unlock];
                return;
            }
            _queued = nil;
            [_lock unlock];
            NSError *failure = nil;
            SWRaster *plane = [frame quarter:&failure];
            if (plane == nil || ![_tracker push:plane time:frame.time - origin error:&failure]) {
                [_lock lock];
                [_failures addObject:SWErrorMessageOf(failure)];
                [_lock unlock];
            }
        }
    }
}

- (void)tick {
    [_lock lock];
    BOOL hasOrigin = _hasOrigin;
    double origin = _origin;
    [_lock unlock];
    if (hasOrigin) {
        [_tracker tick:SWNowMilliseconds() - origin error:nil];
    }
}

- (SWVideoModel *)stop:(SWCancelToken *)token error:(NSError **)error {
    [_lock lock];
    if (_stopped) {
        [_lock unlock];
        SWFail(error, SWErrorNameState, @"the recording already stopped");
        return nil;
    }
    _stopped = YES;
    SWSegmentWriter *writer = _writer;
    _writer = nil;
    [_lock unlock];
    for (NSNumber *listener in _listeners) {
        [SWScreenFeed.shared removeListener:listener.integerValue];
    }
    if (_timer != nil) {
        dispatch_source_cancel(_timer);
    }
    if (writer != nil) {
        [self closeWriter:writer];
    }
    [SWScreenFeed.shared releaseFeed];
    NSString *events = _timeline == nil ? @"[]" : [_timeline stop];
    _timeline = nil;
    while (dispatch_group_wait(_finishing, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
        if ([token failIfCancelled:error]) {
            return nil;
        }
    }
    dispatch_sync(_tracking, ^{
        [self->_tracker finish:nil];
    });
    return [self save:events error:error];
}

- (void)abandon {
    [_lock lock];
    BOOL running = !_stopped;
    [_lock unlock];
    if (!running) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *failure = nil;
            if ([self stop:nil error:&failure] == nil) {
                SWReportRecordingFailure(SWErrorMessageOf(failure));
            }
        }
    });
}

- (double)medianClockDelta {
    if (_clockDeltaCount == 0) {
        return 0;
    }
    double *sorted = malloc(_clockDeltaCount * sizeof(double));
    memcpy(sorted, _clockDeltas, _clockDeltaCount * sizeof(double));
    qsort_b(sorted, _clockDeltaCount, sizeof(double), ^int(const void *a, const void *b) {
        double first = *(const double *)a;
        double second = *(const double *)b;
        return first < second ? -1 : first > second;
    });
    double median = sorted[_clockDeltaCount / 2];
    free(sorted);
    return median;
}

- (SWVideoModel *)save:(NSString *)timeline error:(NSError **)error {
    [_lock lock];
    BOOL hasOrigin = _hasOrigin;
    double origin = _origin;
    double last = _last;
    NSArray<SWRecordingSegment *> *segments = [_segments copy];
    NSArray<NSString *> *failures = [_failures copy];
    double clockOffset = [self medianClockDelta];
    NSMutableArray<NSDictionary *> *feed = [_feed mutableCopy];
    if (_window.active) {
        [feed addObject:SWFeedEvent(_window)];
    }
    [_lock unlock];
    if (!hasOrigin || segments.count == 0) {
        SWFail(error, SWErrorNameUnavailable, @"graphics: the recording got no frames; the screen may be off or another app may hold it");
        return nil;
    }
    if (failures.firstObject != nil) {
        BOOL nothingWritten = YES;
        for (SWRecordingSegment *segment in segments) {
            nothingWritten = nothingWritten && CMTimeCompare(segment.writer.end, kCMTimeZero) == 0;
        }
        if (nothingWritten) {
            SWFail(error, SWErrorNameGeneric, @"graphics: %@", failures.firstObject);
            return nil;
        }
    }
    NSArray<NSDictionary *> *decoded = SWDecodeJSON(timeline);
    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    if ([decoded isKindOfClass:NSArray.class]) {
        [events addObjectsFromArray:decoded];
    }
    [events addObjectsFromArray:feed];
    double duration = MAX(last - origin, 0) + 1000.0 / 60;
    NSDictionary *metadata = @{
        @"version": @1, @"start": @(origin), @"duration": @(SWRounded(duration)), @"scale": @(_geometry.scale),
        @"clockOffset": @(SWRounded(clockOffset)),
        @"screen": @{@"width": @(_geometry.width), @"height": @(_geometry.height)},
        @"segments": [self segmentsJSON:segments duration:duration],
        @"changes": [self changesJSON:segments events:events origin:origin],
        @"events": [self relativeEvents:events origin:origin],
    };
    NSString *encoded = SWEncodeJSON(metadata);
    if (encoded == nil) {
        SWFail(error, SWErrorNameGeneric, @"graphics: encode the recording's metadata");
        return nil;
    }
    if (![[encoded dataUsingEncoding:NSUTF8StringEncoding] writeToURL:SWVideoSidecar(_url) options:NSDataWritingAtomic error:error]) {
        return nil;
    }
    return [[SWVideoModel alloc] initWithURL:_url metadata:metadata error:error];
}

- (NSArray *)segmentsJSON:(NSArray<SWRecordingSegment *> *)segments duration:(double)duration {
    NSMutableArray *described = [NSMutableArray array];
    for (NSUInteger index = 0; index < segments.count; index++) {
        SWRecordingSegment *segment = segments[index];
        double following = index + 1 < segments.count ? segments[index + 1].start : duration;
        [described addObject:@{@"file": segment.file, @"start": @(SWRounded(segment.start)), @"duration": @(SWRounded(following - segment.start)), @"turns": @(segment.turns)}];
    }
    return described;
}

- (NSArray *)changesJSON:(NSArray<SWRecordingSegment *> *)segments events:(NSArray<NSDictionary *> *)events origin:(double)origin {
    NSMutableArray<NSDictionary *> *foreground = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if ([event[@"type"] isEqual:@"foreground"] && SWAsNumber(event[@"time"]) != nil && [event[@"app"] isKindOfClass:NSString.class]) {
            [foreground addObject:event];
        }
    }
    NSMutableArray *described = [NSMutableArray array];
    for (SWChange *change in _tracker.changes) {
        double time = origin + change.start;
        NSString *app = foreground.firstObject[@"app"];
        for (NSDictionary *event in foreground) {
            if (SWAsNumber(event[@"time"]).doubleValue <= time) {
                app = event[@"app"];
            }
        }
        NSInteger turns = 0;
        for (SWRecordingSegment *segment in segments) {
            if (segment.start <= change.start) {
                turns = segment.turns;
            }
        }
        NSInteger width = turns % 2 == 0 ? _geometry.width : _geometry.height;
        [described addObject:SWVideoChangeJSON(change, (double)width / MAX(change.width, 1), _geometry.scale, app)];
    }
    return described;
}

- (NSArray *)relativeEvents:(NSArray<NSDictionary *> *)events origin:(double)origin {
    NSMutableArray<NSDictionary *> *relative = [NSMutableArray array];
    for (NSDictionary *event in events) {
        NSNumber *time = SWAsNumber(event[@"time"]);
        if (time == nil || time.doubleValue < origin) {
            continue;
        }
        NSMutableDictionary *shifted = [event mutableCopy];
        shifted[@"time"] = @(SWRounded(time.doubleValue - origin));
        [relative addObject:shifted];
    }
    return [relative sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        return [first[@"time"] compare:second[@"time"]];
    }];
}

@end
