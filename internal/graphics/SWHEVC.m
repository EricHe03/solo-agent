//go:build darwin && cgo

#import "SWHEVC.h"

#import "SWAccessUnit.h"

@implementation SWRTPClock {
    BOOL _hasLast;
    uint32_t _last;
    int64_t _high;
    BOOL _hasBase;
    int64_t _base;
}

- (CMTime)time:(uint32_t)timestamp {
    if (_hasLast && timestamp < _last && _last - timestamp > 0x80000000u) {
        _high += (int64_t)1 << 32;
    }
    _hasLast = YES;
    _last = timestamp;
    int64_t value = _high + (int64_t)timestamp;
    if (!_hasBase) {
        _hasBase = YES;
        _base = value;
    }
    return CMTimeMake(value - _base, 24000);
}

@end

static NSData *SWFirstNAL(NSArray<NSData *> *nals, NSInteger type) {
    for (NSData *nal in nals) {
        if (SWNALType(nal) == type) {
            return nal;
        }
    }
    return nil;
}

CMVideoFormatDescriptionRef SWHEVCFormat(NSArray<NSData *> *nals) {
    NSData *vps = SWFirstNAL(nals, 32);
    NSData *sps = SWFirstNAL(nals, 33);
    NSData *pps = SWFirstNAL(nals, 34);
    if (vps == nil || sps == nil || pps == nil) {
        return NULL;
    }
    const uint8_t *pointers[3] = {vps.bytes, sps.bytes, pps.bytes};
    const size_t sizes[3] = {vps.length, sps.length, pps.length};
    CMVideoFormatDescriptionRef description = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, pointers, sizes, 4, NULL, &description);
    return status == noErr ? description : NULL;
}

CMSampleBufferRef SWHEVCSample(SWAccessUnit *unit, CMVideoFormatDescriptionRef format, CMTime time, CMTime duration) {
    NSMutableData *payload = [NSMutableData data];
    for (NSData *nal in unit.nals) {
        NSInteger type = SWNALType(nal);
        if (type >= 32 && type <= 34) {
            continue;
        }
        uint32_t length = CFSwapInt32HostToBig((uint32_t)nal.length);
        [payload appendBytes:&length length:sizeof(length)];
        [payload appendData:nal];
    }
    size_t size = payload.length;
    if (size == 0) {
        return NULL;
    }
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr) {
        return NULL;
    }
    CMSampleBufferRef sample = NULL;
    if (CMBlockBufferReplaceDataBytes(payload.bytes, block, 0, size) == noErr) {
        CMSampleTimingInfo timing = {.duration = duration, .presentationTimeStamp = time, .decodeTimeStamp = kCMTimeInvalid};
        CMSampleBufferCreateReady(NULL, block, format, 1, 1, &timing, 1, &size, &sample);
    }
    CFRelease(block);
    if (sample != NULL && !unit.isKeyframe) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
        }
    }
    return sample;
}
