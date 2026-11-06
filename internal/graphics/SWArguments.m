//go:build darwin && cgo

#import "SWArguments.h"

#import "SWError.h"
#import "SWJSON.h"

static BOOL SWAllOfClass(NSArray *array, Class class) {
    for (id item in array) {
        if (![item isKindOfClass:class]) {
            return NO;
        }
    }
    return YES;
}

@implementation SWArguments

- (instancetype)initWithValues:(NSDictionary<NSString *, id> *)values {
    self = [super init];
    if (self) {
        _values = values;
    }
    return self;
}

- (instancetype)initWithJSON:(NSString *)json error:(NSError **)error {
    NSDictionary *values = SWDecodeJSON(json);
    if (![values isKindOfClass:NSDictionary.class]) {
        SWFail(error, SWErrorNameType, @"graphics: the arguments are not a JSON object");
        return nil;
    }
    return [self initWithValues:values];
}

- (NSNumber *)number:(NSString *)key {
    return SWAsNumber(_values[key]);
}

- (double)double:(NSString *)key fallback:(double)fallback {
    NSNumber *number = [self number:key];
    return number == nil ? fallback : number.doubleValue;
}

- (NSInteger)integer:(NSString *)key fallback:(NSInteger)fallback {
    NSNumber *number = [self number:key];
    return number == nil ? fallback : number.integerValue;
}

- (NSString *)string:(NSString *)key {
    id value = _values[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (NSArray *)arrayOf:(Class)class key:(NSString *)key {
    id value = _values[key];
    return [value isKindOfClass:NSArray.class] && SWAllOfClass(value, class) ? value : nil;
}

- (NSArray<NSString *> *)strings:(NSString *)key {
    return [self arrayOf:NSString.class key:key];
}

- (NSArray<NSNumber *> *)numbers:(NSString *)key {
    return [self arrayOf:NSNumber.class key:key];
}

- (BOOL)rect:(NSString *)key into:(CGRect *)rect {
    NSArray<NSNumber *> *numbers = [self numbers:key];
    if (numbers.count != 4) {
        return NO;
    }
    *rect = CGRectMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue);
    return YES;
}

- (BOOL)point:(NSString *)key into:(CGPoint *)point {
    NSArray<NSNumber *> *numbers = [self numbers:key];
    if (numbers.count != 2) {
        return NO;
    }
    *point = CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue);
    return YES;
}

- (NSArray<NSDictionary<NSString *, id> *> *)objects:(NSString *)key {
    return [self arrayOf:NSDictionary.class key:key] ?: @[];
}

- (double)timeout {
    NSNumber *number = [self number:@"timeoutMs"];
    return number == nil ? INFINITY : number.doubleValue;
}

@end
