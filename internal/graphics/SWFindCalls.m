//go:build darwin && cgo

#import "SWArguments.h"
#import "SWCall.h"
#import "SWCancelToken.h"
#import "SWEngine.h"
#import "SWError.h"
#import "SWImageNode.h"
#import "SWJSON.h"
#import "SWScreenFeed.h"
#import "SWScreenSearch.h"
#import "SWVideoModel.h"

static NSMutableDictionary *SWMatchJSON(SWScreenHit *hit, SWImageNode *node, SWEngine *engine) {
    return [@{
        @"frame": SWRectJSON(hit.frame), @"center": SWCenterJSON(hit.frame), @"score": @(round(hit.score * 1000) / 1000),
        @"text": hit.text ?: NSNull.null, @"target": @(hit.target), @"image": @([engine registerObject:node]),
    } mutableCopy];
}

static id SWScreenFindLoop(SWCall *call, SWScreenFeed *feed, SWScreenSearch *search, double started, NSError **error) {
    SWArguments *arguments = call.arguments;
    double timeout = arguments.values[@"timeoutMs"] == nil ? 0 : arguments.timeout;
    NSDate *limit = isfinite(timeout) ? [NSDate dateWithTimeIntervalSinceNow:timeout / 1000] : NSDate.distantFuture;
    NSInteger sequence = 0;
    SWFrame *frame = SWScreenFirstFrame(feed, call.token, &sequence, error);
    if (frame == nil) {
        return nil;
    }
    NSError *failure = nil;
    id result = nil;
    while (result == nil && failure == nil) {
        @autoreleasepool {
            if ([call.token failIfCancelled:&failure]) {
                break;
            }
            SWImageNode *node = [SWImageNode nodeWithFrame:frame];
            SWScreenHit *hit = [search check:node error:&failure];
            if (hit != nil) {
                [search traceName:@"screen.find" started:started hit:hit frameTime:frame.time];
                result = SWMatchJSON(hit, node, call.engine);
                break;
            }
            if (failure != nil) {
                break;
            }
            SWFrame *next = timeout == 0 ? nil : [feed frameAfter:sequence until:limit token:call.token sequence:&sequence error:&failure];
            if (next == nil) {
                if (failure == nil) {
                    [search traceName:@"screen.find" started:started hit:nil frameTime:frame.time];
                    result = NSNull.null;
                }
                break;
            }
            frame = next;
        }
    }
    if (failure != nil) {
        SWFailWith(error, failure);
    }
    return result;
}

id SWCallScreenFind(SWCall *call, NSError **error) {
    double started = SWNowMilliseconds();
    SWScreenSearch *search = [[SWScreenSearch alloc] initWithCall:call firstObject:0 error:error];
    if (search == nil) {
        return nil;
    }
    SWScreenFeed *feed = SWScreenFeed.shared;
    SWScreenGeometry geometry;
    if (![feed acquire:&geometry error:error]) {
        return nil;
    }
    id result = SWScreenFindLoop(call, feed, search, started, error);
    [feed releaseFeed];
    return result;
}

id SWCallVideoFind(SWCall *call, NSError **error) {
    double started = SWNowMilliseconds();
    SWVideoModel *model = [call video:error];
    if (model == nil) {
        return nil;
    }
    SWArguments *arguments = call.arguments;
    SWScreenSearch *search = [[SWScreenSearch alloc] initWithCall:call firstObject:1 error:error];
    if (search == nil) {
        return nil;
    }
    __block NSMutableDictionary *result = nil;
    __block SWScreenHit *found = nil;
    BOOL scanned = [model scanFrom:[arguments double:@"from" fallback:0] to:[arguments double:@"to" fallback:model.duration] token:call.token error:error visitor:^BOOL(SWFrame *frame, BOOL *going, NSError **failure) {
        SWImageNode *node = [SWImageNode nodeWithFrame:frame ofVideo:model];
        NSError *inner = nil;
        SWScreenHit *hit = [search check:node error:&inner];
        if (hit == nil) {
            if (inner != nil) {
                SWFailWith(failure, inner);
                return NO;
            }
            return YES;
        }
        found = hit;
        result = SWMatchJSON(hit, node, call.engine);
        result[@"time"] = @(SWRounded(frame.time));
        *going = NO;
        return YES;
    }];
    if (!scanned) {
        return nil;
    }
    [search traceName:@"recording.find" started:started hit:found frameTime:NAN];
    return result ?: NSNull.null;
}
