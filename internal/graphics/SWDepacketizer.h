#import <Foundation/Foundation.h>

@class SWAccessUnit;

@interface SWDepacketizer : NSObject
- (void)reset;
- (void)push:(const uint8_t *)bytes length:(NSInteger)length arrival:(double)arrival into:(NSMutableArray<SWAccessUnit *> *)done;
@end
