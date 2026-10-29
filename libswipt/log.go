package libSwipt

import (
	"sync/atomic"

	"github.com/swipt-automation/swipt/internal/log"
)

const (
	LogLevelError int32 = int32(log.LevelError)
	LogLevelWarn  int32 = int32(log.LevelWarn)
	LogLevelInfo  int32 = int32(log.LevelInfo)
	LogLevelDebug int32 = int32(log.LevelDebug)
)

type LogHandler interface {
	Log(level int32, message string)
}

type logTarget struct {
	handler LogHandler
	level   log.Level
}

var currentLogTarget atomic.Pointer[logTarget]

func SetLogHandler(handler LogHandler, maximumLevel int32) {
	currentLogTarget.Store(&logTarget{handler: handler, level: log.Level(maximumLevel)})
}

func newLogFactory() *log.Factory {
	var options log.Options
	if target := currentLogTarget.Load(); target != nil {
		options = log.Options{Level: target.level, PlatformWriter: target}
	}
	return log.NewFactory(options)
}

func (t *logTarget) WriteMessage(level log.Level, message string) {
	t.handler.Log(int32(level), message)
}
