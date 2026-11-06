//go:build darwin && cgo

#import "SWAccessUnit.h"

NSInteger SWNALType(NSData *nal) {
    return (((const uint8_t *)nal.bytes)[0] >> 1) & 0x3f;
}

@implementation SWAccessUnit

- (instancetype)initWithTimestamp:(uint32_t)timestamp arrival:(double)arrival profile:(uint16_t)profile {
    self = [super init];
    if (self) {
        _nals = [NSMutableArray array];
        _rtpTimestamp = timestamp;
        _arrival = arrival;
        _profile = profile;
    }
    return self;
}

- (BOOL)isKeyframe {
    for (NSData *nal in _nals) {
        NSInteger type = SWNALType(nal);
        if (type >= 16 && type <= 23) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasParameterSets {
    for (NSData *nal in _nals) {
        if (SWNALType(nal) == 33) {
            return YES;
        }
    }
    return NO;
}

- (NSInteger)turns {
    if ((_profile & 0xf000) != 0x9000) {
        return 0;
    }
    static const NSInteger table[4] = {0, 2, 3, 1};
    return table[(_profile >> 8) & 3];
}

@end
