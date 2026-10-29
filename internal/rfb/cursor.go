package rfb

import (
	"github.com/swipt-automation/swipt/internal/bgra"
)

type Cursor struct {
	bgra.Cursor
	CacheID uint32
}
