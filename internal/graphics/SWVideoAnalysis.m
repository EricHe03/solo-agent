//go:build darwin && cgo

#import "SWCancelToken.h"
#import "SWChangeTracker.h"
#import "SWError.h"
#import "SWRaster.h"
#import "SWVideoModel.h"

static const NSInteger SWAnalysisFactor = 4;

SWVideoModel *SWVideoAnalyze(NSURL *url, SWCancelToken *token, NSError **error) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = SWVideoFirstTrack(asset, error);
    if (track == nil) {
        return nil;
    }
    CGSize size = track.naturalSize;
    CGAffineTransform transform = track.preferredTransform;
    NSInteger turns = (((NSInteger)round(atan2(transform.b, transform.a) / (M_PI / 2))) % 4 + 4) % 4;
    NSInteger width = (NSInteger)size.width;
    NSInteger height = (NSInteger)size.height;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:error];
    if (reader == nil) {
        return nil;
    }
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferWidthKey: @(MAX(width / SWAnalysisFactor, 1)),
        (__bridge id)kCVPixelBufferHeightKey: @(MAX(height / SWAnalysisFactor, 1)),
    }];
    output.alwaysCopiesSampleData = NO;
    [reader addOutput:output];
    if (![reader startReading]) {
        SWFail(error, SWErrorNameData, @"graphics: read %@: %@", url.lastPathComponent, reader.error.localizedDescription ?: @"unknown");
        return nil;
    }
    SWChangeTracker *tracker = [SWChangeTracker new];
    double lastTime = 0;
    NSError *failure = nil;
    while (failure == nil) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (sample == NULL) {
                break;
            }
            CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
            if (![token failIfCancelled:&failure] && image != NULL) {
                double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000;
                SWRaster *raster = [[SWRaster alloc] initWithPixelBuffer:image width:CVPixelBufferGetWidth(image) height:CVPixelBufferGetHeight(image) error:&failure];
                SWRaster *gray = raster == nil ? nil : SWRasterGrayscale(raster, &failure);
                SWRaster *upright = gray == nil ? nil : SWRasterRotatedQuarters(gray, turns, &failure);
                if (upright != nil && [tracker push:upright time:time error:&failure]) {
                    lastTime = time;
                }
            }
            CFRelease(sample);
        }
    }
    if (failure != nil) {
        SWFailWith(error, failure);
        return nil;
    }
    if (![tracker finish:error]) {
        return nil;
    }
    double duration = MAX(CMTimeGetSeconds(asset.duration) * 1000, lastTime);
    NSInteger uprightWidth = turns % 2 == 0 ? width : height;
    NSMutableArray *changes = [NSMutableArray array];
    for (SWChange *change in tracker.changes) {
        [changes addObject:SWVideoChangeJSON(change, (double)uprightWidth / MAX(change.width, 1), 1, nil)];
    }
    NSDictionary *metadata = @{
        @"duration": @(duration), @"scale": @1, @"screen": @{@"width": @(width), @"height": @(height)},
        @"segments": @[@{@"file": url.lastPathComponent, @"start": @0, @"duration": @(duration), @"turns": @(turns)}],
        @"changes": changes,
    };
    return [[SWVideoModel alloc] initWithURL:url metadata:metadata error:error];
}
