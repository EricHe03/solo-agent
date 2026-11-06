//go:build darwin && cgo

#import "SWArguments.h"
#import "SWCall.h"
#import "SWEngine.h"
#import "SWError.h"
#import "SWGoBridge.h"
#import "SWImageNode.h"
#import "SWRaster.h"
#import "SWRecordingSession.h"
#import "SWVideoModel.h"

id SWCallRecord(SWCall *call, NSError **error) {
    NSURL *url = [call authorized:[call.arguments string:@"path"] write:YES error:error];
    if (url == nil) {
        return nil;
    }
    SWRecordingSession *session = [SWRecordingSession startWithURL:url timeline:[call.context watchTimeline] token:call.token error:error];
    return session == nil ? nil : @{@"recording": @([call.engine registerObject:session])};
}

id SWCallRecordingStop(SWCall *call, NSError **error) {
    SWRecordingSession *session = call.objects.firstObject;
    if (![session isKindOfClass:SWRecordingSession.class]) {
        SWFail(error, SWErrorNameType, @"stop needs a Recording");
        return nil;
    }
    SWVideoModel *model = [session stop:call.token error:error];
    return model == nil ? nil : @{@"video": @([call.engine registerObject:model])};
}

id SWCallVideoOpen(SWCall *call, NSError **error) {
    NSURL *url = [call authorized:[call.arguments string:@"path"] write:NO error:error];
    if (url == nil) {
        return nil;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        SWFail(error, SWErrorNameNotFound, @"there is no file at %@", url.path);
        return nil;
    }
    SWVideoModel *model = SWVideoOpen(url, call.token, error);
    return model == nil ? nil : @{@"video": @([call.engine registerObject:model])};
}

id SWCallVideoGrid(SWCall *call, NSError **error) {
    SWVideoModel *model = [call video:error];
    if (model == nil) {
        return nil;
    }
    SWArguments *arguments = call.arguments;
    SWRaster *grid = SWVideoGrid(model, [arguments numbers:@"times"] ?: model.defaultGridTimes, [arguments integer:@"columns" fallback:4], [arguments integer:@"width" fallback:240], call.token, error);
    return grid == nil ? nil : @{@"image": @([call.engine registerObject:[SWImageNode nodeWithRaster:grid transform:CGAffineTransformIdentity]])};
}

id SWCallVideoDiff(SWCall *call, NSError **error) {
    SWVideoModel *model = [call video:error];
    if (model == nil) {
        return nil;
    }
    SWArguments *arguments = call.arguments;
    return SWCallDifference([model nodeAt:[arguments double:@"from" fallback:0]], [model nodeAt:[arguments double:@"to" fallback:0]], [arguments integer:@"threshold" fallback:SWDefaultDifferenceThreshold], call.token, error);
}

id SWCallVideoExport(SWCall *call, NSError **error) {
    SWVideoModel *model = [call video:error];
    if (model == nil) {
        return nil;
    }
    NSString *path = [call.arguments string:@"path"] ?: [model.url.URLByDeletingPathExtension.path stringByAppendingString:@"-export.mp4"];
    NSURL *target = [call authorized:path write:YES error:error];
    NSString *exported = target == nil ? nil : SWVideoExport(model, call.arguments, target, call.token, error);
    return exported == nil ? nil : @{@"path": exported};
}
