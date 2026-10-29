package media

import (
	"bytes"
	"compress/zlib"
	"io"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	payloadTypeHEVC   = 100
	maxNegotiatorBlob = 1 << 20
)

func parseNegotiatorBlob(compressed []byte) (protoMessage, error) {
	reader, err := zlib.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return nil, E.Cause(err, "media: decompress negotiator blob")
	}
	inflated, err := io.ReadAll(io.LimitReader(reader, maxNegotiatorBlob))
	if err != nil {
		return nil, E.Cause(err, "media: decompress negotiator blob")
	}
	return parseProto(inflated)
}
