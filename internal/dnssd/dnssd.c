#include "dnssd.h"

#include <arpa/inet.h>

#include "_cgo_export.h"

DNSServiceErrorType swipt_dnssd_register(DNSServiceRef connection, DNSServiceRef *ref, const char *name, const char *type, uint16_t port, uint16_t txtLength, const void *txt, uintptr_t handle) {
	*ref = connection;
	return DNSServiceRegister(ref, kDNSServiceFlagsShareConnection, 0, name, type, NULL, NULL, htons(port), txtLength, txt, (DNSServiceRegisterReply)swiptDNSSDRegistered, (void *)handle);
}
