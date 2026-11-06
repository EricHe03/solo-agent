//go:build darwin && cgo

#import "SWError.h"

#import "SWJSON.h"

NSString *const SWErrorNameGeneric = @"Error";
NSString *const SWErrorNameType = @"TypeError";
NSString *const SWErrorNameRange = @"RangeError";
NSString *const SWErrorNameData = @"DataError";
NSString *const SWErrorNameTimeout = @"TimeoutError";
NSString *const SWErrorNameUnavailable = @"UnavailableError";
NSString *const SWErrorNameState = @"InvalidStateError";
NSString *const SWErrorNameAbort = @"AbortError";
NSString *const SWErrorNameNotFound = @"NotFoundError";

static NSString *const SWErrorDomain = @"io.nekohasekai.swipt.graphics";
static NSString *const SWErrorNameKey = @"name";

NSError *SWMakeError(NSString *name, NSString *message) {
    return [NSError errorWithDomain:SWErrorDomain code:0 userInfo:@{SWErrorNameKey: name, NSLocalizedDescriptionKey: message}];
}

void SWFail(NSError **error, NSString *name, NSString *format, ...) {
    if (error == NULL) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    *error = SWMakeError(name, message);
}

void SWFailWith(NSError **error, NSError *cause) {
    if (error != NULL) {
        *error = cause;
    }
}

NSError *SWErrorFromFailure(NSString *failure) {
    NSDictionary *decoded = SWDecodeJSON(failure);
    NSString *name = nil;
    NSString *message = nil;
    if ([decoded isKindOfClass:NSDictionary.class]) {
        name = [decoded[@"name"] isKindOfClass:NSString.class] ? decoded[@"name"] : nil;
        message = [decoded[@"message"] isKindOfClass:NSString.class] ? decoded[@"message"] : nil;
    }
    return SWMakeError(name ?: SWErrorNameGeneric, message ?: failure);
}

NSError *SWErrorAborted(void) {
    return SWMakeError(SWErrorNameAbort, @"the operation was aborted");
}

NSError *SWErrorEnded(void) {
    return SWMakeError(SWErrorNameAbort, @"the JavaScript session ended");
}

NSString *SWErrorNameOf(NSError *error) {
    if ([error.domain isEqualToString:SWErrorDomain]) {
        return error.userInfo[SWErrorNameKey];
    }
    return SWErrorNameGeneric;
}

NSString *SWErrorMessageOf(NSError *error) {
    return error.localizedDescription;
}
