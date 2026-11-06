#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface SWArguments : NSObject
@property (nonatomic, readonly) NSDictionary<NSString *, id> *values;

- (instancetype)initWithValues:(NSDictionary<NSString *, id> *)values;
- (instancetype)initWithJSON:(NSString *)json error:(NSError **)error;
- (NSNumber *)number:(NSString *)key;
- (double)double:(NSString *)key fallback:(double)fallback;
- (NSInteger)integer:(NSString *)key fallback:(NSInteger)fallback;
- (NSString *)string:(NSString *)key;
- (NSArray<NSString *> *)strings:(NSString *)key;
- (NSArray<NSNumber *> *)numbers:(NSString *)key;
- (BOOL)rect:(NSString *)key into:(CGRect *)rect;
- (BOOL)point:(NSString *)key into:(CGPoint *)point;
- (NSArray<NSDictionary<NSString *, id> *> *)objects:(NSString *)key;
- (double)timeout;
@end
