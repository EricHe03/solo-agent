#import <Foundation/Foundation.h>

@interface SWAccessUnit : NSObject
@property (nonatomic, readonly) NSMutableArray<NSData *> *nals;
@property (nonatomic, readonly) uint32_t rtpTimestamp;
@property (nonatomic, readonly) double arrival;
@property (nonatomic, readonly) uint16_t profile;
@property (nonatomic) BOOL damaged;
@property (nonatomic, readonly) BOOL isKeyframe;
@property (nonatomic, readonly) BOOL hasParameterSets;
@property (nonatomic, readonly) NSInteger turns;

- (instancetype)initWithTimestamp:(uint32_t)timestamp arrival:(double)arrival profile:(uint16_t)profile;
@end

NSInteger SWNALType(NSData *nal);
