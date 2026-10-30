//go:build darwin && !ios && cgo

package main

/*
#include <dns_sd.h>
#include <stdint.h>
#include <stdlib.h>

DNSServiceErrorType swiptBrowse(DNSServiceRef *ref, const char *type, uintptr_t context);
DNSServiceErrorType swiptResolve(DNSServiceRef *ref, const char *name, const char *type, const char *domain, uintptr_t context);
*/
import "C"

import (
	"context"
	"errors"
	"runtime/cgo"
	"slices"
	"strings"
	"time"
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/api/discovery"
	"golang.org/x/sys/unix"
)

const resolveLimit = time.Second

type bonjourInstance struct {
	name, kind, domain string
}

type browseState struct {
	found []bonjourInstance
}

type resolveState struct {
	done bool
	host string
	port uint16
}

//export swiptBrowsed
func swiptBrowsed(context C.uintptr_t, flags C.uint32_t, code C.int32_t, name, kind, domain *C.char) {
	state := cgo.Handle(context).Value().(*browseState)
	if code != C.kDNSServiceErr_NoError || flags&C.kDNSServiceFlagsAdd == 0 {
		return
	}
	instance := bonjourInstance{name: C.GoString(name), kind: C.GoString(kind), domain: C.GoString(domain)}
	if !slices.Contains(state.found, instance) {
		state.found = append(state.found, instance)
	}
}

//export swiptResolved
func swiptResolved(context C.uintptr_t, code C.int32_t, host *C.char, port C.uint16_t) {
	state := cgo.Handle(context).Value().(*resolveState)
	state.done = true
	if code == C.kDNSServiceErr_NoError {
		state.host, state.port = strings.TrimSuffix(C.GoString(host), "."), uint16(port)
	}
}

func processResults(ctx context.Context, ref C.DNSServiceRef, deadline time.Time, finished func() bool) error {
	descriptor := int32(C.DNSServiceRefSockFD(ref))
	for !finished() && ctx.Err() == nil {
		wait := time.Until(deadline)
		if wait <= 0 {
			return nil
		}
		ready, err := unix.Poll([]unix.PollFd{{Fd: descriptor, Events: unix.POLLIN}}, int(wait/time.Millisecond)+1)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		if ready > 0 {
			if code := C.DNSServiceProcessResult(ref); code != C.kDNSServiceErr_NoError {
				return E.New("Bonjour error ", int(code))
			}
		}
	}
	return nil
}

func browseBonjour(ctx context.Context, wait time.Duration) ([]bonjourService, error) {
	state := &browseState{}
	handle := cgo.NewHandle(state)
	defer handle.Delete()
	kind := C.CString(discovery.ServiceType)
	defer C.free(unsafe.Pointer(kind))
	var ref C.DNSServiceRef
	if code := C.swiptBrowse(&ref, kind, C.uintptr_t(handle)); code != C.kDNSServiceErr_NoError {
		return nil, E.New("browse Bonjour: error ", int(code))
	}
	err := processResults(ctx, ref, time.Now().Add(wait), func() bool { return false })
	C.DNSServiceRefDeallocate(ref)
	if err != nil {
		return nil, E.Cause(err, "browse Bonjour")
	}
	var services []bonjourService
	for _, instance := range state.found {
		service, resolved := resolveBonjour(ctx, instance)
		if resolved {
			services = append(services, service)
		}
	}
	return services, nil
}

func resolveBonjour(ctx context.Context, instance bonjourInstance) (bonjourService, bool) {
	state := &resolveState{}
	handle := cgo.NewHandle(state)
	defer handle.Delete()
	name, kind, domain := C.CString(instance.name), C.CString(instance.kind), C.CString(instance.domain)
	defer C.free(unsafe.Pointer(name))
	defer C.free(unsafe.Pointer(kind))
	defer C.free(unsafe.Pointer(domain))
	var ref C.DNSServiceRef
	if C.swiptResolve(&ref, name, kind, domain, C.uintptr_t(handle)) != C.kDNSServiceErr_NoError {
		return bonjourService{}, false
	}
	err := processResults(ctx, ref, time.Now().Add(resolveLimit), func() bool { return state.done })
	C.DNSServiceRefDeallocate(ref)
	if err != nil || state.host == "" {
		return bonjourService{}, false
	}
	return bonjourService{name: instance.name, host: state.host, port: state.port}, true
}
