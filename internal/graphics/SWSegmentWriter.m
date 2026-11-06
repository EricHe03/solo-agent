//go:build darwin && cgo

#import "SWSegmentWriter.h"

#import <AVFoundation/AVFoundation.h>

#import "SWAccessUnit.h"
#import "SWError.h"
#import "SWHEVC.h"

@implementation SWSegmentWriter {
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    SWRTPClock *_clock;
    SWAccessUnit *_pending;
    CMTime _pendingTime;
    NSString *_failure;
}

- (instancetype)initWithURL:(NSURL *)url format:(CMVideoFormatDescriptionRef)format turns:(NSInteger)turns error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _format = (CMVideoFormatDescriptionRef)CFRetain(format);
    _turns = turns;
    _clock = [SWRTPClock new];
    _end = kCMTimeZero;
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    _writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeQuickTimeMovie error:error];
    if (_writer == nil) {
        return nil;
    }
    _input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:format];
    _input.expectsMediaDataInRealTime = YES;
    _input.transform = CGAffineTransformMakeRotation(turns * M_PI / 2);
    if (![_writer canAddInput:_input]) {
        SWFail(error, SWErrorNameGeneric, @"graphics: add the video track");
        return nil;
    }
    [_writer addInput:_input];
    if (![_writer startWriting]) {
        SWFail(error, SWErrorNameGeneric, @"graphics: start writing: %@", _writer.error.localizedDescription ?: @"unknown");
        return nil;
    }
    [_writer startSessionAtSourceTime:kCMTimeZero];
    return self;
}

- (void)dealloc {
    if (_format != NULL) {
        CFRelease(_format);
    }
}

- (CMTime)append:(SWAccessUnit *)unit {
    CMTime time = [_clock time:unit.rtpTimestamp];
    if (_pending != nil) {
        [self write:_pending time:_pendingTime duration:CMTimeSubtract(time, _pendingTime)];
    }
    _pending = unit;
    _pendingTime = time;
    return time;
}

- (void)write:(SWAccessUnit *)unit time:(CMTime)time duration:(CMTime)duration {
    CMSampleBufferRef sample = SWHEVCSample(unit, _format, time, duration);
    if (sample == NULL) {
        return;
    }
    if (_input.isReadyForMoreMediaData) {
        if ([_input appendSampleBuffer:sample]) {
            _end = CMTimeAdd(time, duration);
        } else if (_failure == nil) {
            _failure = _writer.error.localizedDescription ?: @"the writer rejected a frame";
        }
    }
    CFRelease(sample);
}

- (void)finish:(void (^)(NSString *))done {
    if (_pending != nil) {
        [self write:_pending time:_pendingTime duration:CMTimeMake(400, 24000)];
        _pending = nil;
    }
    [_input markAsFinished];
    AVAssetWriter *writer = _writer;
    NSString *failure = _failure;
    [writer finishWritingWithCompletionHandler:^{
        done(writer.status == AVAssetWriterStatusCompleted ? failure : writer.error.localizedDescription ?: failure ?: @"the video could not be finished");
    }];
}

@end
