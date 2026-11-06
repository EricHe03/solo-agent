//go:build darwin && cgo

#import "SWJSON.h"

#import "SWError.h"

double SWRounded(double value) {
    return isfinite(value) ? round(value * 100) / 100 : 0;
}

NSArray<NSNumber *> *SWPointJSON(CGPoint point) {
    return @[@(SWRounded(point.x)), @(SWRounded(point.y))];
}

NSArray<NSNumber *> *SWRectJSON(CGRect rect) {
    return @[@(SWRounded(CGRectGetMinX(rect))), @(SWRounded(CGRectGetMinY(rect))), @(SWRounded(CGRectGetWidth(rect))), @(SWRounded(CGRectGetHeight(rect)))];
}

NSArray<NSNumber *> *SWCenterJSON(CGRect rect) {
    return SWPointJSON(CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)));
}

double SWNowMilliseconds(void) {
    return NSDate.date.timeIntervalSince1970 * 1000;
}

NSNumber *SWAsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

NSString *SWEncodeJSON(id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return nil;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

id SWDecodeJSON(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

NSString *SWOutcomeFailure(NSError *error) {
    return SWEncodeJSON(@{@"error": @{@"name": SWErrorNameOf(error), @"message": SWErrorMessageOf(error)}})
        ?: @"{\"error\":{\"name\":\"Error\",\"message\":\"graphics: the error does not pass through JSON\"}}";
}

NSString *SWOutcomeSuccess(id value) {
    return SWEncodeJSON(@{@"value": value}) ?: SWOutcomeFailure(SWMakeError(SWErrorNameGeneric, @"graphics: the result does not pass through JSON"));
}
