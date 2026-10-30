//go:build darwin && !ios && cgo

#include <arpa/inet.h>
#include <dns_sd.h>
#include <stdint.h>

#include "_cgo_export.h"

static void browseReply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
                        const char *name, const char *type, const char *domain, void *context) {
    swiptBrowsed((uintptr_t)context, flags, error, (char *)name, (char *)type, (char *)domain);
}

static void resolveReply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
                         const char *fullName, const char *host, uint16_t port, uint16_t txtLength,
                         const unsigned char *txt, void *context) {
    swiptResolved((uintptr_t)context, error, (char *)host, ntohs(port));
}

DNSServiceErrorType swiptBrowse(DNSServiceRef *ref, const char *type, uintptr_t context) {
    return DNSServiceBrowse(ref, 0, 0, type, NULL, browseReply, (void *)context);
}

DNSServiceErrorType swiptResolve(DNSServiceRef *ref, const char *name, const char *type, const char *domain, uintptr_t context) {
    return DNSServiceResolve(ref, 0, 0, name, type, domain, resolveReply, (void *)context);
}
