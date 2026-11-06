#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

double SWRounded(double value);
NSArray<NSNumber *> *SWPointJSON(CGPoint point);
NSArray<NSNumber *> *SWRectJSON(CGRect rect);
NSArray<NSNumber *> *SWCenterJSON(CGRect rect);
double SWNowMilliseconds(void);
NSNumber *SWAsNumber(id value);
NSString *SWEncodeJSON(id object);
id SWDecodeJSON(NSString *text);
NSString *SWOutcomeSuccess(id value);
NSString *SWOutcomeFailure(NSError *error);
