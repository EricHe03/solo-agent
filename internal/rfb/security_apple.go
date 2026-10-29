package rfb

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/binary"
	"io"
	"sync"
)

func randomBytes(length int) []byte {
	data := make([]byte, length)
	rand.Read(data)
	return data
}

type fieldReader struct {
	data []byte
	err  error
}

func (r *fieldReader) take(length int) []byte {
	if r.err != nil {
		return nil
	}
	if length > len(r.data) {
		r.err = io.ErrUnexpectedEOF
		return nil
	}
	value := r.data[:length]
	r.data = r.data[length:]
	return value
}

func (r *fieldReader) u8() int {
	value := r.take(1)
	if value == nil {
		return 0
	}
	return int(value[0])
}

func (r *fieldReader) u16() int {
	value := r.take(2)
	if value == nil {
		return 0
	}
	return int(binary.BigEndian.Uint16(value))
}

// ScreenSharing derives 128 bytes with PBKDF2-HMAC-SHA-512 using the iteration count
// from the SRP challenge (ScreenSharing 776.27, macOS 27.0.1 26A434,
// UUID EC0B2C20-F816-3FCE-822D-F9403C09EB50, _srp_client_mech_step 0x1cc13a454..0x1cc13a490,
// 0x1cc13ab60..0x1cc13ab98).
func passwordKey(password string, salt []byte, iterations int) []byte {
	key := make([]byte, 128)
	var wait sync.WaitGroup
	for offset := 0; offset < len(key); offset += sha512.Size {
		block := key[offset : offset+sha512.Size]
		index := uint32(offset/sha512.Size + 1)
		wait.Go(func() {
			prf := hmac.New(sha512.New, []byte(password))
			prf.Write(salt)
			prf.Write(binary.BigEndian.AppendUint32(nil, index))
			sum := prf.Sum(nil)
			copy(block, sum)
			for range iterations - 1 {
				prf.Reset()
				prf.Write(sum)
				sum = prf.Sum(sum[:0])
				subtle.XORBytes(block, block, sum)
			}
		})
	}
	wait.Wait()
	return key
}
