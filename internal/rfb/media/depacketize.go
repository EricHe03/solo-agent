package media

const (
	hevcNALAggregation = 48
	hevcNALFragment    = 49
	hevcNALSPS         = 33
)

func hevcNALType(nal []byte) int {
	return int(nal[0]>>1) & 0x3f
}
