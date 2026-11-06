#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@class SWAccessUnit;

@interface SWRTPClock : NSObject
- (CMTime)time:(uint32_t)timestamp;
@end

CMVideoFormatDescriptionRef SWHEVCFormat(NSArray<NSData *> *nals) CF_RETURNS_RETAINED;
CMSampleBufferRef SWHEVCSample(SWAccessUnit *unit, CMVideoFormatDescriptionRef format, CMTime time, CMTime duration) CF_RETURNS_RETAINED;
