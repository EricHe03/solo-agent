//go:build darwin && cgo

package automation

import (
	"strings"
	"unicode/utf8"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/jsc"
)

func (e *engine) encodeText(arguments []jsc.Value) (any, error) {
	values, err := texts(arguments, 1)
	if err != nil {
		return nil, err
	}
	return jsc.Bytes(values[0]), nil
}

func (e *engine) decodeText(arguments []jsc.Value) (any, error) {
	if len(arguments) < 2 {
		return nil, E.New("expected the data and fatal")
	}
	data, isBytes := arguments[0].Bytes()
	if !isBytes {
		return nil, E.New("the data is not a Uint8Array")
	}
	if utf8.Valid(data) {
		return string(data), nil
	}
	if arguments[1].Number() != 0 {
		return nil, nil
	}
	return decodeUTF8(data), nil
}

func decodeUTF8(data []byte) string {
	var out strings.Builder
	out.Grow(len(data))
	needed, seen := 0, 0
	var point rune
	lower, upper := byte(0x80), byte(0xbf)
	for index := 0; index < len(data); {
		b := data[index]
		if needed == 0 {
			index++
			switch {
			case b < 0x80:
				out.WriteByte(b)
			case b >= 0xc2 && b <= 0xdf:
				needed, point = 1, rune(b&0x1f)
			case b >= 0xe0 && b <= 0xef:
				lower, upper = 0x80, 0xbf
				if b == 0xe0 {
					lower = 0xa0
				} else if b == 0xed {
					upper = 0x9f
				}
				needed, point = 2, rune(b&0x0f)
			case b >= 0xf0 && b <= 0xf4:
				lower, upper = 0x80, 0xbf
				if b == 0xf0 {
					lower = 0x90
				} else if b == 0xf4 {
					upper = 0x8f
				}
				needed, point = 3, rune(b&0x07)
			default:
				out.WriteRune(utf8.RuneError)
			}
			continue
		}
		if b < lower || b > upper {
			needed, seen, point = 0, 0, 0
			lower, upper = 0x80, 0xbf
			out.WriteRune(utf8.RuneError)
			continue
		}
		index++
		lower, upper = 0x80, 0xbf
		point = point<<6 | rune(b&0x3f)
		if seen++; seen < needed {
			continue
		}
		out.WriteRune(point)
		needed, seen, point = 0, 0, 0
	}
	if needed != 0 {
		out.WriteRune(utf8.RuneError)
	}
	return out.String()
}
