//go:build darwin && cgo

#import "SWGoBridge.h"

#include "_cgo_export.h"

#import "SWError.h"

static char *SWCString(NSString *text) {
    return (char *)text.UTF8String;
}

static NSError *SWTakeFailure(char *failure) {
    NSError *error = SWErrorFromFailure([NSString stringWithUTF8String:failure]);
    free(failure);
    return error;
}

@implementation SWGoObject

- (instancetype)initWithHandle:(uintptr_t)handle {
    self = [super init];
    if (self) {
        _handle = handle;
    }
    return self;
}

- (void)dealloc {
    swiptGraphicsRelease(_handle);
}

@end

@implementation SWTimelineWatch

- (NSString *)stop {
    char *events = swiptGraphicsStopTimeline(self.handle);
    NSString *text = [NSString stringWithUTF8String:events];
    free(events);
    return text;
}

@end

@implementation SWCallContext

- (BOOL)cancelled {
    return swiptGraphicsCancelled(self.handle);
}

- (BOOL)tracing {
    return swiptGraphicsTracing(self.handle);
}

- (void)traceName:(NSString *)name detail:(NSString *)detail started:(double)started duration:(double)duration {
    swiptGraphicsTrace(self.handle, SWCString(name), SWCString(detail), started, duration);
}

- (BOOL)authorize:(NSString *)path write:(BOOL)write error:(NSError **)error {
    char *failure = swiptGraphicsAuthorize(self.handle, SWCString(path), write);
    if (failure == NULL) {
        return YES;
    }
    SWFailWith(error, SWTakeFailure(failure));
    return NO;
}

- (NSData *)screenshotWithScale:(double *)scale error:(NSError **)error {
    swipt_graphics_screenshot shot = swiptGraphicsScreenshot(self.handle);
    if (shot.failure != NULL) {
        SWFailWith(error, SWTakeFailure(shot.failure));
        return nil;
    }
    *scale = shot.scale;
    return [NSData dataWithBytesNoCopy:shot.image length:shot.length freeWhenDone:YES];
}

- (SWTimelineWatch *)watchTimeline {
    return [[SWTimelineWatch alloc] initWithHandle:swiptGraphicsWatchTimeline(self.handle)];
}

- (void)publish:(NSString *)value {
    swiptGraphicsPublish(self.handle, SWCString(value));
}

@end

@implementation SWDeviceFeed

+ (instancetype)openWithError:(NSError **)error {
    swipt_graphics_screen screen = swiptGraphicsOpenScreen();
    if (screen.failure != NULL) {
        SWFailWith(error, SWTakeFailure(screen.failure));
        return nil;
    }
    SWDeviceFeed *feed = [[self alloc] initWithHandle:screen.feed];
    feed->_width = (NSInteger)screen.width;
    feed->_height = (NSInteger)screen.height;
    feed->_scale = MAX(screen.scale, 1);
    return feed;
}

- (void)requestKeyFrame {
    swiptGraphicsRequestKeyFrame(self.handle);
}

- (void)close {
    swiptGraphicsCloseScreen(self.handle);
}

@end

void SWLogError(NSString *message) {
    swiptGraphicsLogError(SWCString(message));
}

void SWReportRecordingFailure(NSString *message) {
    swiptGraphicsRecordingFailed(SWCString(message));
}
