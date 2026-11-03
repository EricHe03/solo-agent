//go:build darwin && cgo

package computer

/*
#cgo LDFLAGS: -framework CoreFoundation -framework SystemConfiguration
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
*/
import "C"

import "unsafe"

func Name() string {
	name := C.SCDynamicStoreCopyComputerName(0, nil)
	if name == 0 {
		return ""
	}
	defer C.CFRelease(C.CFTypeRef(name))
	return goString(name)
}

func LocalHostName() string {
	name := C.SCDynamicStoreCopyLocalHostName(0)
	if name == 0 {
		return ""
	}
	defer C.CFRelease(C.CFTypeRef(name))
	return goString(name)
}

func Languages() []string {
	list := C.CFLocaleCopyPreferredLanguages()
	if list == 0 {
		return nil
	}
	defer C.CFRelease(C.CFTypeRef(list))
	count := int(C.CFArrayGetCount(list))
	languages := make([]string, 0, count)
	for index := range count {
		languages = append(languages, goString(C.CFStringRef(C.CFArrayGetValueAtIndex(list, C.CFIndex(index)))))
	}
	return languages
}

func goString(value C.CFStringRef) string {
	length := C.CFStringGetMaximumSizeForEncoding(C.CFStringGetLength(value), C.kCFStringEncodingUTF8) + 1
	buffer := make([]byte, length)
	if C.CFStringGetCString(value, (*C.char)(unsafe.Pointer(&buffer[0])), length, C.kCFStringEncodingUTF8) == 0 {
		return ""
	}
	return C.GoString((*C.char)(unsafe.Pointer(&buffer[0])))
}
