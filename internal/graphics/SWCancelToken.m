//go:build darwin && cgo

#import "SWCancelToken.h"

#import <stdatomic.h>

#import "SWError.h"

@implementation SWCancelToken {
    BOOL (^_cancelled)(void);
    atomic_bool _flag;
}

- (instancetype)initWithCancelled:(BOOL (^)(void))cancelled {
    self = [super init];
    if (self) {
        _cancelled = [cancelled copy];
    }
    return self;
}

- (BOOL)isCancelled {
    return atomic_load(&_flag) || _cancelled();
}

- (void)cancel {
    atomic_store(&_flag, true);
}

- (BOOL)failIfCancelled:(NSError **)error {
    if (!self.isCancelled) {
        return NO;
    }
    SWFailWith(error, SWErrorAborted());
    return YES;
}

@end
