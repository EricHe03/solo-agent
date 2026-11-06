//go:build darwin && cgo

#import "SWArguments.h"
#import "SWCall.h"
#import "SWCancelToken.h"
#import "SWEngine.h"
#import "SWError.h"
#import "SWGoBridge.h"
#import "SWImageNode.h"
#import "SWJSON.h"
#import "SWRaster.h"
#import "SWScreenComparison.h"
#import "SWScreenFeed.h"

id SWCallScreenshot(SWCall *call, NSError **error) {
    double started = SWNowMilliseconds();
    double scale = 0;
    NSData *data = [call.context screenshotWithScale:&scale error:error];
    if (data == nil) {
        return nil;
    }
    if (data.length == 0) {
        SWFail(error, SWErrorNameUnavailable, @"graphics: the device sent no screenshot");
        return nil;
    }
    if ([call.token failIfCancelled:error]) {
        return nil;
    }
    SWImageNode *node = [SWImageNode nodeWithEncoded:data scale:scale > 0 ? @(scale) : nil timestamp:started error:error];
    return node == nil ? nil : @{@"image": @([call.engine registerObject:node])};
}

id SWCallScreenGet(SWCall *call, NSError **error) {
    SWScreenFeed *feed = SWScreenFeed.shared;
    SWScreenGeometry geometry;
    if (![feed acquire:&geometry error:error]) {
        return nil;
    }
    NSInteger sequence = 0;
    SWFrame *frame = SWScreenFirstFrame(feed, call.token, &sequence, error);
    [feed releaseFeed];
    return frame == nil ? nil : @{@"image": @([call.engine registerObject:[SWImageNode nodeWithFrame:frame]])};
}

static NSDate *SWDeadline(SWArguments *arguments) {
    double timeout = arguments.timeout;
    return isfinite(timeout) ? [NSDate dateWithTimeIntervalSinceNow:timeout / 1000] : NSDate.distantFuture;
}

static id SWWaitForChange(SWCall *call, SWScreenFeed *feed, NSError **error) {
    SWArguments *arguments = call.arguments;
    NSDate *limit = SWDeadline(arguments);
    NSInteger sequence = 0;
    SWFrame *frame = SWScreenFirstFrame(feed, call.token, &sequence, error);
    if (frame == nil) {
        return nil;
    }
    SWImageNode *given = [call.objects.firstObject isKindOfClass:SWImageNode.class] ? call.objects.firstObject : nil;
    SWImageNode *reference = given ?: [SWImageNode nodeWithFrame:frame];
    CGRect region;
    BOOL hasRegion = [arguments rect:@"region" into:&region];
    SWScreenComparison *comparison = [[SWScreenComparison alloc] initWithNode:reference region:hasRegion ? &region : NULL threshold:[arguments integer:@"threshold" fallback:SWDefaultDifferenceThreshold] error:error];
    SWRaster *before = comparison == nil ? nil : [comparison plane:reference token:call.token error:error];
    if (before == nil) {
        return nil;
    }
    BOOL check = call.objects.firstObject != nil;
    NSError *failure = nil;
    id result = nil;
    while (result == nil && failure == nil) {
        @autoreleasepool {
            if (!check) {
                frame = [feed frameAfter:sequence until:limit token:call.token sequence:&sequence error:&failure];
                if (frame == nil) {
                    if (failure == nil) {
                        failure = SWMakeError(SWErrorNameTimeout, [NSString stringWithFormat:@"the screen did not change within %ld ms", (long)arguments.timeout]);
                    }
                    break;
                }
            }
            check = NO;
            SWImageNode *node = [SWImageNode nodeWithFrame:frame];
            SWRaster *plane = [comparison plane:node token:call.token error:&failure];
            BOOL changed = NO;
            if (plane != nil && [comparison changed:before from:plane result:&changed error:&failure] && changed) {
                result = @{@"image": @([call.engine registerObject:node])};
            }
        }
    }
    if (failure != nil) {
        SWFailWith(error, failure);
    }
    return result;
}

id SWCallWaitForChange(SWCall *call, NSError **error) {
    SWScreenFeed *feed = SWScreenFeed.shared;
    SWScreenGeometry geometry;
    if (![feed acquire:&geometry error:error]) {
        return nil;
    }
    id result = SWWaitForChange(call, feed, error);
    [feed releaseFeed];
    return result;
}

static id SWWaitForStable(SWCall *call, SWScreenFeed *feed, NSError **error) {
    SWArguments *arguments = call.arguments;
    NSDate *limit = SWDeadline(arguments);
    double quiet = [arguments double:@"durationMs" fallback:500] / 1000;
    NSInteger sequence = 0;
    SWFrame *frame = SWScreenFirstFrame(feed, call.token, &sequence, error);
    if (frame == nil) {
        return nil;
    }
    SWImageNode *node = [SWImageNode nodeWithFrame:frame];
    CGRect region;
    BOOL hasRegion = [arguments rect:@"region" into:&region];
    SWScreenComparison *comparison = [[SWScreenComparison alloc] initWithNode:node region:hasRegion ? &region : NULL threshold:[arguments integer:@"threshold" fallback:SWDefaultDifferenceThreshold] error:error];
    SWRaster *last = comparison == nil ? nil : [comparison plane:node token:call.token error:error];
    if (last == nil) {
        return nil;
    }
    NSDate *changedAt = NSDate.date;
    NSError *failure = nil;
    while (failure == nil) {
        @autoreleasepool {
            NSTimeInterval remaining = quiet + changedAt.timeIntervalSinceNow;
            if (remaining <= 0) {
                return @{@"image": @([call.engine registerObject:node])};
            }
            if (limit.timeIntervalSinceNow <= 0) {
                failure = SWMakeError(SWErrorNameTimeout, [NSString stringWithFormat:@"the screen did not settle within %ld ms", (long)arguments.timeout]);
                break;
            }
            NSDate *until = [limit earlierDate:[NSDate dateWithTimeIntervalSinceNow:remaining]];
            SWFrame *next = [feed frameAfter:sequence until:until token:call.token sequence:&sequence error:&failure];
            if (next == nil) {
                continue;
            }
            node = [SWImageNode nodeWithFrame:next];
            SWRaster *current = [comparison plane:node token:call.token error:&failure];
            BOOL changed = NO;
            if (current != nil && [comparison changed:last from:current result:&changed error:&failure]) {
                if (changed) {
                    changedAt = NSDate.date;
                }
                last = current;
            }
        }
    }
    SWFailWith(error, failure);
    return nil;
}

id SWCallWaitForStable(SWCall *call, NSError **error) {
    SWScreenFeed *feed = SWScreenFeed.shared;
    SWScreenGeometry geometry;
    if (![feed acquire:&geometry error:error]) {
        return nil;
    }
    id result = SWWaitForStable(call, feed, error);
    [feed releaseFeed];
    return result;
}

BOOL SWCallWatch(SWCall *call, NSError **error) {
    if (![call.method isEqualToString:@"screen.watch"]) {
        SWFail(error, SWErrorNameType, @"graphics: there is no stream %@", call.method);
        return NO;
    }
    SWScreenFeed *feed = SWScreenFeed.shared;
    SWScreenGeometry geometry;
    if (![feed acquire:&geometry error:error]) {
        return NO;
    }
    NSInteger sequence = 0;
    NSInteger previous = 0;
    NSError *failure = nil;
    while (failure == nil) {
        @autoreleasepool {
            SWFrame *next = [feed frameAfter:sequence until:NSDate.distantFuture token:call.token sequence:&sequence error:&failure];
            if (next == nil) {
                continue;
            }
            NSInteger identifier = [call.engine registerObject:[SWImageNode nodeWithFrame:next]];
            if (previous != 0) {
                [call.engine drop:previous];
            }
            previous = identifier;
            [call.context publish:[NSString stringWithFormat:@"%ld", (long)identifier]];
        }
    }
    if (previous != 0) {
        [call.engine drop:previous];
    }
    [feed releaseFeed];
    SWFailWith(error, failure);
    return NO;
}
