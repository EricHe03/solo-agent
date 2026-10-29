package rfb

import (
	"fmt"

	E "github.com/sagernet/sing/common/exceptions"
)

var ErrAuthenticationFailed = E.New("rfb: authentication failed")

type ProtocolVersion struct {
	Major int
	Minor int
}

func (v ProtocolVersion) String() string {
	return fmt.Sprintf("%03d.%03d", v.Major, v.Minor)
}

func (v ProtocolVersion) apple() bool {
	return v.Major == 3 && (v.Minor == 889 || v.Minor == 888)
}

const (
	ServerFlagControlPrivilege uint32 = 0x02
	ServerFlagExtended         uint32 = 0x10
)
