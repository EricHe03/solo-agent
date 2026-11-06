#import <Foundation/Foundation.h>

@class SWRaster;

@interface SWChange : NSObject
@property (nonatomic, readonly) double before;
@property (nonatomic, readonly) double start;
@property (nonatomic, readonly) double after;
@property (nonatomic, readonly) NSData *regions;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@end

@interface SWChangeTracker : NSObject
@property (nonatomic, readonly) NSArray<SWChange *> *changes;

- (BOOL)push:(SWRaster *)plane time:(double)time error:(NSError **)error;
- (BOOL)tick:(double)now error:(NSError **)error;
- (BOOL)finish:(NSError **)error;
@end
