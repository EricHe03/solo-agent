//go:build darwin && cgo

#import "SWChangeTracker.h"

#import <CoreGraphics/CoreGraphics.h>

#import "SWRaster.h"
#import "SWRegions.h"

static const NSInteger SWChangeThreshold = 24;
static const double SWChangeSettle = 300;

@implementation SWChange

- (instancetype)initWithBefore:(double)before start:(double)start after:(double)after regions:(NSData *)regions width:(NSInteger)width height:(NSInteger)height {
    self = [super init];
    if (self) {
        _before = before;
        _start = start;
        _after = after;
        _regions = regions;
        _width = width;
        _height = height;
    }
    return self;
}

@end

@implementation SWChangeTracker {
    NSMutableArray<SWChange *> *_changes;
    SWRaster *_reference;
    SWRaster *_last;
    double _lastTime;
    BOOL _active;
    double _start;
    double _before;
    double _motion;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _changes = [NSMutableArray array];
    }
    return self;
}

- (NSArray<SWChange *> *)changes {
    return _changes;
}

- (BOOL)changed:(SWRaster *)a from:(SWRaster *)b result:(BOOL *)result error:(NSError **)error {
    if (a.width != b.width || a.height != b.height) {
        *result = YES;
        return YES;
    }
    NSInteger changed = 0;
    if (SWRegionsDifference(a, b, SWChangeThreshold, &changed, error) == nil) {
        return NO;
    }
    *result = changed >= SWRegionsMinimumChange(a.width * a.height);
    return YES;
}

- (BOOL)push:(SWRaster *)plane time:(double)time error:(NSError **)error {
    BOOL succeeded = YES;
    if (_reference == nil || _last == nil) {
        _reference = plane;
    } else if (_active) {
        BOOL moved = NO;
        succeeded = [self changed:_last from:plane result:&moved error:error];
        if (succeeded) {
            if (moved) {
                _motion = time;
            } else if (time - _motion >= SWChangeSettle) {
                succeeded = [self close:error];
            }
        }
    } else {
        BOOL moved = NO;
        succeeded = [self changed:_reference from:plane result:&moved error:error];
        if (succeeded && moved) {
            _active = YES;
            _start = time;
            _before = _lastTime;
            _motion = time;
        }
    }
    _last = plane;
    _lastTime = time;
    return succeeded;
}

- (BOOL)tick:(double)now error:(NSError **)error {
    if (_active && now - _motion >= SWChangeSettle) {
        return [self close:error];
    }
    return YES;
}

- (BOOL)finish:(NSError **)error {
    return _active ? [self close:error] : YES;
}

- (BOOL)close:(NSError **)error {
    if (!_active || _reference == nil || _last == nil) {
        return YES;
    }
    SWRaster *reference = _reference;
    SWRaster *last = _last;
    _active = NO;
    _reference = last;
    if (reference.width != last.width || reference.height != last.height) {
        CGRect whole = CGRectMake(0, 0, last.width, last.height);
        [_changes addObject:[[SWChange alloc] initWithBefore:_before start:_start after:_motion regions:[NSData dataWithBytes:&whole length:sizeof(whole)] width:last.width height:last.height]];
        return YES;
    }
    NSInteger changed = 0;
    SWRaster *mask = SWRegionsDifference(reference, last, SWChangeThreshold, &changed, error);
    if (mask == nil) {
        return NO;
    }
    if (changed < SWRegionsMinimumChange(last.width * last.height)) {
        return YES;
    }
    NSData *regions = SWRegionsMerged(mask, 2, nil, error);
    if (regions == nil) {
        return NO;
    }
    [_changes addObject:[[SWChange alloc] initWithBefore:_before start:_start after:_motion regions:regions width:last.width height:last.height]];
    return YES;
}

@end
