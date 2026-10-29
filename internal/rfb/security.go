package rfb

import (
	"strconv"
)

type SecurityType uint8

const (
	SecurityNone        SecurityType = 1
	SecurityVNCPassword SecurityType = 2
	SecurityAppleDH     SecurityType = 30
	SecurityAskObserve  SecurityType = 31
	SecurityAskControl  SecurityType = 32
	SecurityAppleRSA    SecurityType = 33
	SecurityApplePSK    SecurityType = 34
	SecurityKerberos    SecurityType = 35
	SecurityAppleSRP    SecurityType = 36
)

var securityNames = map[SecurityType]string{
	SecurityNone:        "none",
	SecurityVNCPassword: "vnc-password",
	SecurityAppleDH:     "apple-dh",
	SecurityAskObserve:  "ask-observe",
	SecurityAskControl:  "ask-control",
	SecurityAppleRSA:    "apple-rsa-srp",
	SecurityApplePSK:    "apple-psk",
	SecurityKerberos:    "kerberos",
	SecurityAppleSRP:    "apple-srp",
}

func (t SecurityType) String() string {
	name, found := securityNames[t]
	if found {
		return name + "(" + strconv.Itoa(int(t)) + ")"
	}
	return "security(" + strconv.Itoa(int(t)) + ")"
}
