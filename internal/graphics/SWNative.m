//go:build darwin && cgo

#import "SWNative.h"

#import "SWArguments.h"
#import "SWCall.h"
#import "SWEngine.h"
#import "SWError.h"
#import "SWHandles.h"
#import "SWImageNode.h"
#import "SWJavaScript.h"
#import "SWRecognition.h"
#import "SWRecordingSession.h"
#import "SWVideoModel.h"

@implementation SWNative {
    SWEngine *_engine;
}

- (instancetype)initWithEngine:(SWEngine *)engine {
    self = [super init];
    if (self) {
        _engine = engine;
    }
    return self;
}

- (JSValue *)prepare:(NSString *)method :(NSString *)arguments :(JSValue *)objects {
    JSContext *context = JSContext.currentContext;
    NSError *error = nil;
    SWArguments *parsed = [[SWArguments alloc] initWithJSON:arguments error:&error];
    if (parsed == nil) {
        return SWJavaScriptFail(error);
    }
    NSMutableArray *unwrapped = [NSMutableArray array];
    int32_t count = [objects valueForProperty:@"length"].toInt32;
    for (int32_t index = 0; index < count; index++) {
        JSValue *item = [objects valueAtIndex:index];
        NSData *data = SWJavaScriptData(item);
        if (data != nil) {
            [unwrapped addObject:data];
            continue;
        }
        id object = item.toObject;
        if ([object isKindOfClass:SWImageHandle.class]) {
            [unwrapped addObject:((SWImageHandle *)object).node];
        } else if ([object isKindOfClass:SWRecordingHandle.class]) {
            [unwrapped addObject:((SWRecordingHandle *)object).session];
        } else if ([object isKindOfClass:SWVideoHandle.class]) {
            [unwrapped addObject:((SWVideoHandle *)object).model];
        } else {
            return SWJavaScriptFail(SWMakeError(SWErrorNameType, [NSString stringWithFormat:@"graphics: argument %d of %@ is not an Image, a Recording, a Video or a Uint8Array", index + 1, method]));
        }
    }
    SWCall *call = [[SWCall alloc] initWithMethod:method arguments:parsed objects:unwrapped];
    return [JSValue valueWithDouble:(double)[_engine prepare:call] inContext:context];
}

- (JSValue *)take:(NSInteger)identifier {
    JSContext *context = JSContext.currentContext;
    id object = [_engine take:identifier];
    if ([object isKindOfClass:SWImageNode.class]) {
        SWJavaScriptReportCost(((SWImageNode *)object).estimatedBytes);
        return [JSValue valueWithObject:[[SWImageHandle alloc] initWithNode:object] inContext:context];
    }
    if ([object isKindOfClass:SWRecordingSession.class]) {
        return [JSValue valueWithObject:[[SWRecordingHandle alloc] initWithSession:object] inContext:context];
    }
    if ([object isKindOfClass:SWVideoModel.class]) {
        return [JSValue valueWithObject:[[SWVideoHandle alloc] initWithModel:object] inContext:context];
    }
    if ([object isKindOfClass:SWRecognizedText.class]) {
        return [JSValue valueWithObject:[[SWTextHandle alloc] initWithText:object] inContext:context];
    }
    return [JSValue valueWithNullInContext:context];
}

- (JSValue *)bytes:(NSInteger)identifier {
    id data = [_engine take:identifier];
    if (![data isKindOfClass:NSData.class]) {
        return [JSValue valueWithNullInContext:JSContext.currentContext];
    }
    return SWJavaScriptBytes(data);
}

@end
