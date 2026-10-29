package media

func unescapeRBSP(data []byte) []byte {
	output := make([]byte, 0, len(data))
	zeros := 0
	for _, value := range data {
		if zeros >= 2 && value == 3 {
			zeros = 0
			continue
		}
		output = append(output, value)
		if value == 0 {
			zeros++
		} else {
			zeros = 0
		}
	}
	return output
}

type bitReader struct {
	data     []byte
	position int
	overrun  bool
}

func (r *bitReader) bit() uint {
	if r.position >= len(r.data)*8 {
		r.overrun = true
		return 0
	}
	value := uint(r.data[r.position/8]>>(7-r.position%8)) & 1
	r.position++
	return value
}

func (r *bitReader) bits(count int) uint {
	var value uint
	for i := 0; i < count; i++ {
		value = value<<1 | r.bit()
	}
	return value
}

func (r *bitReader) flag() bool {
	return r.bit() == 1
}

func (r *bitReader) unsignedGolomb() uint {
	zeros := 0
	for r.bit() == 0 {
		if r.overrun || zeros > 31 {
			r.overrun = true
			return 0
		}
		zeros++
	}
	return 1<<zeros - 1 + r.bits(zeros)
}

func HEVCPictureSize(sps []byte) (width, height int, ok bool) {
	if len(sps) < 3 {
		return 0, 0, false
	}
	r := &bitReader{data: unescapeRBSP(sps[2:])}
	_, _, width, height = readHEVCSPSHeader(r)
	return width, height, !r.overrun
}

func readHEVCSPSHeader(r *bitReader) (maxSubLayersMinus1, chromaFormat, width, height int) {
	r.bits(4)
	maxSubLayersMinus1 = int(r.bits(3))
	r.bits(1)
	skipHEVCProfileTierLevel(r, maxSubLayersMinus1)
	r.unsignedGolomb()
	chromaFormat = int(r.unsignedGolomb())
	if chromaFormat == 3 {
		r.bits(1)
	}
	width = int(r.unsignedGolomb())
	height = int(r.unsignedGolomb())
	return
}

func skipHEVCProfileTierLevel(r *bitReader, maxSubLayersMinus1 int) {
	r.bits(8)
	r.bits(32)
	r.bits(48)
	r.bits(8)
	profilePresent := make([]bool, maxSubLayersMinus1)
	levelPresent := make([]bool, maxSubLayersMinus1)
	for i := 0; i < maxSubLayersMinus1; i++ {
		profilePresent[i] = r.flag()
		levelPresent[i] = r.flag()
	}
	if maxSubLayersMinus1 > 0 {
		for i := maxSubLayersMinus1; i < 8; i++ {
			r.bits(2)
		}
	}
	for i := 0; i < maxSubLayersMinus1; i++ {
		if profilePresent[i] {
			r.bits(88)
		}
		if levelPresent[i] {
			r.bits(8)
		}
	}
}
