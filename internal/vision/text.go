//go:build darwin && cgo

package vision

/*
#cgo CFLAGS: -x objective-c -fmodules -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework CoreGraphics -framework ImageIO -framework Vision

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#include <stdlib.h>

typedef struct {
	char *text;
	double x, y, width, height;
} vision_text;

static char *vision_recognize_text(const void *bytes, size_t length, const char *language, vision_text **texts, size_t *count) {
	@autoreleasepool {
		CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:bytes length:length], NULL);
		if (source == NULL) {
			return strdup("decode the image");
		}
		CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
		CFRelease(source);
		if (image == NULL) {
			return strdup("decode the image");
		}
		double imageWidth = CGImageGetWidth(image), imageHeight = CGImageGetHeight(image);
		// Vision reads with the model of the first recognition language, en-US
		// by default, and ignores the rest; without language detection, it also
		// drops the diacritics of Latin text (Mac14,3, macOS 27.0.1 26A434).
		VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
		request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
		request.recognitionLanguages = @[@(language)];
		if (@available(iOS 16.0, *)) {
			request.automaticallyDetectsLanguage = YES;
		}
		NSError *error = nil;
		BOOL performed = [[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}] performRequests:@[request] error:&error];
		CGImageRelease(image);
		if (!performed) {
			return strdup(error.localizedDescription.UTF8String);
		}
		NSArray<VNRecognizedTextObservation *> *results = request.results;
		*texts = calloc(results.count, sizeof(vision_text));
		*count = 0;
		for (VNRecognizedTextObservation *observation in results) {
			VNRecognizedText *top = [observation topCandidates:1].firstObject;
			if (top == nil) {
				continue;
			}
			CGRect box = observation.boundingBox;
			(*texts)[(*count)++] = (vision_text){
				.text = strdup(top.string.UTF8String),
				.x = box.origin.x * imageWidth,
				.y = (1 - box.origin.y - box.size.height) * imageHeight,
				.width = box.size.width * imageWidth,
				.height = box.size.height * imageHeight,
			};
		}
		return NULL;
	}
}

static char *vision_supported_languages(char **languages) {
	@autoreleasepool {
		VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
		request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
		NSError *error = nil;
		NSArray<NSString *> *supported = [request supportedRecognitionLanguagesAndReturnError:&error];
		if (supported == nil) {
			return strdup(error.localizedDescription.UTF8String);
		}
		*languages = strdup([supported componentsJoinedByString:@"\n"].UTF8String);
		return NULL;
	}
}
*/
import "C"

import (
	"context"
	"strings"
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"
)

type Text struct {
	String              string
	X, Y, Width, Height float64
}

// Vision compiles each model the first time the text needs it and caches it
// per program and system build, in
// ~/Library/Caches/<program>/com.apple.e5rt.e5bundlecache/<build>; the first
// recognition in a program took 20–45 s (Mac14,3, macOS 27.0.1 26A434).
func RecognizeText(ctx context.Context, data []byte, language string) ([]Text, error) {
	type result struct {
		texts []Text
		err   error
	}
	done := make(chan result, 1)
	go func() {
		texts, err := recognizeText(data, language)
		done <- result{texts, err}
	}()
	select {
	case it := <-done:
		return it.texts, it.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func recognizeText(data []byte, language string) ([]Text, error) {
	cLanguage := C.CString(language)
	defer C.free(unsafe.Pointer(cLanguage))
	var texts *C.vision_text
	var count C.size_t
	message := C.vision_recognize_text(unsafe.Pointer(unsafe.SliceData(data)), C.size_t(len(data)), cLanguage, &texts, &count)
	if message != nil {
		defer C.free(unsafe.Pointer(message))
		return nil, E.New("vision: ", C.GoString(message))
	}
	defer C.free(unsafe.Pointer(texts))
	out := make([]Text, 0, count)
	for _, text := range unsafe.Slice(texts, count) {
		out = append(out, Text{
			String: C.GoString(text.text),
			X:      float64(text.x),
			Y:      float64(text.y),
			Width:  float64(text.width),
			Height: float64(text.height),
		})
		C.free(unsafe.Pointer(text.text))
	}
	return out, nil
}

func SupportedLanguages() ([]string, error) {
	var languages *C.char
	message := C.vision_supported_languages(&languages)
	if message != nil {
		defer C.free(unsafe.Pointer(message))
		return nil, E.New("vision: ", C.GoString(message))
	}
	defer C.free(unsafe.Pointer(languages))
	return strings.Split(C.GoString(languages), "\n"), nil
}
