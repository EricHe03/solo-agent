#include <dns_sd.h>
#include <stdint.h>

DNSServiceErrorType swipt_dnssd_register(DNSServiceRef connection, DNSServiceRef *ref, const char *name, const char *type, uint16_t port, uint16_t txtLength, const void *txt, uintptr_t handle);
