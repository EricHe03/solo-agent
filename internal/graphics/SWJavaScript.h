#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

void SWJavaScriptReportCost(NSInteger bytes);
JSValue *SWJavaScriptFail(NSError *error);
JSValue *SWJavaScriptBytes(NSData *data);
NSData *SWJavaScriptData(JSValue *value);
