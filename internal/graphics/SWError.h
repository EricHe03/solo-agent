#import <Foundation/Foundation.h>

extern NSString *const SWErrorNameGeneric;
extern NSString *const SWErrorNameType;
extern NSString *const SWErrorNameRange;
extern NSString *const SWErrorNameData;
extern NSString *const SWErrorNameTimeout;
extern NSString *const SWErrorNameUnavailable;
extern NSString *const SWErrorNameState;
extern NSString *const SWErrorNameAbort;
extern NSString *const SWErrorNameNotFound;

NSError *SWMakeError(NSString *name, NSString *message);
void SWFail(NSError **error, NSString *name, NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);
void SWFailWith(NSError **error, NSError *cause);
NSError *SWErrorFromFailure(NSString *failure);
NSError *SWErrorAborted(void);
NSError *SWErrorEnded(void);
NSString *SWErrorNameOf(NSError *error);
NSString *SWErrorMessageOf(NSError *error);
