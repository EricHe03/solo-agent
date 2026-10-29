package media

import (
	"encoding/binary"
)

const (
	rtcpFullIntraRequest = 192
	rtcpSenderReport     = 200
	rtcpReceiverReport   = 201
	rtcpApplication      = 204
)

func rtcpPackets(compound []byte, fn func(packet []byte)) {
	for len(compound) >= 8 {
		length := 4 * (int(binary.BigEndian.Uint16(compound[2:])) + 1)
		if length > len(compound) {
			return
		}
		fn(compound[:length])
		compound = compound[length:]
	}
}
