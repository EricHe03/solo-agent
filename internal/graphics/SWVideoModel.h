#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "SWFrame.h"

@class SWArguments;
@class SWCancelToken;
@class SWChange;
@class SWImageNode;
@class SWRaster;

@interface SWVideoSegment : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) double start;
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) NSInteger turns;
@end

@interface SWVideoModel : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) double start;
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) double scale;
@property (nonatomic, readonly) NSArray<NSDictionary *> *changes;

- (instancetype)initWithURL:(NSURL *)url metadata:(NSDictionary *)metadata error:(NSError **)error;
- (void)pixelSizeAt:(double)time width:(NSInteger *)width height:(NSInteger *)height;
- (SWRaster *)rasterAt:(double)time token:(SWCancelToken *)token error:(NSError **)error;
- (BOOL)scanFrom:(double)from to:(double)to token:(SWCancelToken *)token error:(NSError **)error visitor:(BOOL (^)(SWFrame *frame, BOOL *going, NSError **error))visitor;
- (NSString *)info;
- (SWImageNode *)nodeAt:(double)time;
- (NSArray<NSNumber *> *)defaultGridTimes;
@end

NSURL *SWVideoSidecar(NSURL *url);
AVAssetTrack *SWVideoFirstTrack(AVURLAsset *asset, NSError **error);
NSDictionary *SWVideoChangeJSON(SWChange *change, double factor, double scale, NSString *app);
SWVideoModel *SWVideoOpen(NSURL *url, SWCancelToken *token, NSError **error);
SWVideoModel *SWVideoAnalyze(NSURL *url, SWCancelToken *token, NSError **error);
SWRaster *SWVideoGrid(SWVideoModel *model, NSArray<NSNumber *> *times, NSInteger columns, NSInteger cellWidth, SWCancelToken *token, NSError **error);
NSString *SWVideoExport(SWVideoModel *model, SWArguments *arguments, NSURL *target, SWCancelToken *token, NSError **error);
