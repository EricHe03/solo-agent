//go:build darwin && cgo

#import <CoreText/CoreText.h>

#import "SWCancelToken.h"
#import "SWError.h"
#import "SWRaster.h"
#import "SWVideoModel.h"

static const NSInteger SWGridLabel = 30;
static const NSInteger SWGridGap = 4;

static void SWDrawLabel(CGContextRef context, CTFontRef font, CGColorRef color, double time, CGFloat x, CGFloat y) {
    NSInteger milliseconds = (NSInteger)round(time);
    NSString *text = [NSString stringWithFormat:@"%ld:%02ld.%03ld", (long)(milliseconds / 60000), (long)(milliseconds / 1000 % 60), (long)(milliseconds % 1000)];
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:@{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color,
    }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGContextSetTextPosition(context, x, y);
    CTLineDraw(line, context);
    CFRelease(line);
}

static BOOL SWDrawLabels(SWRaster *canvas, NSArray<NSNumber *> *times, NSInteger columns, NSInteger cellWidth, NSInteger cellHeight, NSError **error) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(canvas.data, canvas.width, canvas.height, 8, canvas.rowBytes, space, (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (context == NULL) {
        SWFail(error, SWErrorNameGeneric, @"graphics: create the drawing context");
        return NO;
    }
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 20, NULL) ?: CTFontCreateWithName(CFSTR("Helvetica"), 20, NULL);
    CGColorRef white = CGColorCreateGenericGray(1, 1);
    for (NSUInteger index = 0; index < times.count; index++) {
        NSInteger x = SWGridGap + (NSInteger)index % columns * (cellWidth + SWGridGap);
        NSInteger y = SWGridGap + (NSInteger)index / columns * (cellHeight + SWGridLabel + SWGridGap);
        SWDrawLabel(context, font, white, times[index].doubleValue, x + 6, canvas.height - y - SWGridLabel + 8);
    }
    CGColorRelease(white);
    CFRelease(font);
    CGContextRelease(context);
    return YES;
}

SWRaster *SWVideoGrid(SWVideoModel *model, NSArray<NSNumber *> *times, NSInteger columns, NSInteger cellWidth, SWCancelToken *token, NSError **error) {
    NSArray<NSNumber *> *sorted = [times sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
    NSMutableArray<SWRaster *> *cells = [NSMutableArray array];
    for (NSNumber *time in sorted) {
        if ([token failIfCancelled:error]) {
            return nil;
        }
        SWRaster *raster = [model rasterAt:time.doubleValue token:token error:error];
        if (raster == nil) {
            return nil;
        }
        [cells addObject:raster];
    }
    SWRaster *first = cells.firstObject;
    if (first == nil) {
        SWFail(error, SWErrorNameRange, @"graphics: the grid has no frames");
        return nil;
    }
    NSInteger cellHeight = MAX((NSInteger)round((double)first.height * cellWidth / first.width), 1);
    NSInteger count = (NSInteger)cells.count;
    NSInteger shownColumns = MIN(columns, count);
    NSInteger rows = (count + shownColumns - 1) / shownColumns;
    SWRaster *canvas = [[SWRaster alloc] initWithWidth:shownColumns * cellWidth + (shownColumns + 1) * SWGridGap height:rows * (cellHeight + SWGridLabel + SWGridGap) + SWGridGap channels:4];
    vImage_Buffer buffer = canvas.buffer;
    const Pixel_8888 background = {24, 24, 24, 255};
    if (!SWRequire(vImageBufferFill_ARGB8888(&buffer, background, kvImageNoFlags), @"fill the grid", error)) {
        return nil;
    }
    for (NSInteger index = 0; index < count; index++) {
        @autoreleasepool {
            SWRaster *cell = cells[index];
            NSInteger height = MAX((NSInteger)round((double)cell.height * cellWidth / cell.width), 1);
            NSError *failure = nil;
            SWRaster *resized = SWRasterResized(cell, cellWidth, MIN(height, cellHeight), &failure);
            if (resized == nil) {
                SWFailWith(error, failure);
                return nil;
            }
            NSInteger x = SWGridGap + index % shownColumns * (cellWidth + SWGridGap);
            NSInteger y = SWGridGap + index / shownColumns * (cellHeight + SWGridLabel + SWGridGap);
            [resized copyInto:canvas x:x y:y + SWGridLabel];
        }
    }
    return SWDrawLabels(canvas, sorted, shownColumns, cellWidth, cellHeight, error) ? canvas : nil;
}
