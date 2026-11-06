//go:build darwin && cgo

#import "SWSegmentReader.h"

#import <AVFoundation/AVFoundation.h>

#import "SWCancelToken.h"
#import "SWError.h"
#import "SWVideoModel.h"

@implementation SWDecodedBuffer

- (instancetype)initWithSample:(CMSampleBufferRef)sample image:(CVImageBufferRef)image {
    self = [super init];
    if (self) {
        _time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        _buffer = CVPixelBufferRetain(image);
    }
    return self;
}

- (void)dealloc {
    CVPixelBufferRelease(_buffer);
}

@end

@implementation SWSegmentReader {
    AVURLAsset *_asset;
    AVAssetTrack *_track;
    NSLock *_lock;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    SWDecodedBuffer *_current;
    SWDecodedBuffer *_pending;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _asset = [AVURLAsset URLAssetWithURL:url options:nil];
    _track = SWVideoFirstTrack(_asset, error);
    if (_track == nil) {
        return nil;
    }
    _lock = [NSLock new];
    return self;
}

- (AVAssetReader *)openAt:(double)seconds error:(NSError **)error {
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_asset error:error];
    if (reader == nil) {
        return nil;
    }
    reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(MAX(seconds - 1, 0), 600), kCMTimePositiveInfinity);
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_track outputSettings:@{(__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        SWFail(error, SWErrorNameGeneric, @"graphics: read the video");
        return nil;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        SWFail(error, SWErrorNameGeneric, @"graphics: read the video: %@", reader.error.localizedDescription ?: @"unknown");
        return nil;
    }
    return reader;
}

- (SWDecodedBuffer *)nextFrom:(AVAssetReaderOutput *)output {
    while (YES) {
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (sample == NULL) {
            return nil;
        }
        CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
        SWDecodedBuffer *decoded = image == NULL ? nil : [[SWDecodedBuffer alloc] initWithSample:sample image:image];
        CFRelease(sample);
        if (decoded != nil) {
            return decoded;
        }
    }
}

- (SWDecodedBuffer *)frameLockedAt:(double)seconds error:(NSError **)error {
    BOOL reusable = _current != nil && _current.time <= seconds && seconds - _current.time < 2;
    if (!reusable) {
        [_reader cancelReading];
        AVAssetReader *reader = [self openAt:seconds error:error];
        if (reader == nil) {
            return nil;
        }
        _reader = reader;
        _output = (AVAssetReaderTrackOutput *)reader.outputs.firstObject;
        _current = nil;
        _pending = nil;
    }
    if (_pending != nil && _pending.time <= seconds) {
        _current = _pending;
        _pending = nil;
    }
    while (_pending == nil) {
        @autoreleasepool {
            SWDecodedBuffer *sample = [self nextFrom:_output];
            if (sample == nil) {
                break;
            }
            if (sample.time <= seconds + 0.0005) {
                _current = sample;
            } else {
                _pending = sample;
            }
        }
    }
    if (_current != nil || _pending != nil) {
        return _current ?: _pending;
    }
    SWFail(error, SWErrorNameData, @"graphics: the video has no frame at %ld ms", (long)(seconds * 1000));
    return nil;
}

- (SWDecodedBuffer *)frameAt:(double)seconds error:(NSError **)error {
    [_lock lock];
    SWDecodedBuffer *frame = [self frameLockedAt:seconds error:error];
    [_lock unlock];
    return frame;
}

- (BOOL)eachFrom:(double)start through:(double)end token:(SWCancelToken *)token going:(BOOL *)going error:(NSError **)error visitor:(SWFrameVisitor)visitor {
    AVAssetReader *reader = [self openAt:start error:error];
    if (reader == nil) {
        return NO;
    }
    AVAssetReaderOutput *output = reader.outputs.firstObject;
    SWDecodedBuffer *held = nil;
    NSError *failure = nil;
    BOOL succeeded = YES;
    *going = YES;
    while (succeeded && *going) {
        @autoreleasepool {
            SWDecodedBuffer *sample = [self nextFrom:output];
            if (sample == nil) {
                if (held != nil) {
                    succeeded = visitor(start, held.buffer, going, &failure);
                }
                break;
            }
            if ([token failIfCancelled:&failure]) {
                succeeded = NO;
                break;
            }
            if (sample.time <= start + 0.0005) {
                held = sample;
                continue;
            }
            if (held != nil) {
                SWDecodedBuffer *shown = held;
                held = nil;
                succeeded = visitor(start, shown.buffer, going, &failure);
                if (!succeeded || !*going) {
                    break;
                }
            }
            if (sample.time > end + 0.0005) {
                break;
            }
            succeeded = visitor(sample.time, sample.buffer, going, &failure);
        }
    }
    [reader cancelReading];
    if (!succeeded) {
        SWFailWith(error, failure);
    }
    return succeeded;
}

@end
