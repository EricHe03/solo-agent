package libSwipt

import (
	"context"
	"encoding/json"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/automation"
	"github.com/swipt-automation/swipt/internal/device"
)

const screenOpenLimit = 20 * time.Second

type GraphicsHandler interface {
	Entry() int64
	Run(engine int64, call int64, context *GraphicsContext) string
	Watch(engine int64, call int64, context *GraphicsContext, publisher *GraphicsPublisher) string
}

type graphicsBridge struct {
	handler GraphicsHandler
}

func (b graphicsBridge) Entry() uintptr {
	return uintptr(b.handler.Entry())
}

func (b graphicsBridge) Run(engine uint64, call int64, context *automation.GraphicsCall) (json.RawMessage, error) {
	return graphicsOutcome(b.handler.Run(int64(engine), call, &GraphicsContext{call: context}))
}

func (b graphicsBridge) Watch(engine uint64, call int64, context *automation.GraphicsCall, publish func(any)) error {
	_, err := graphicsOutcome(b.handler.Watch(int64(engine), call, &GraphicsContext{call: context}, &GraphicsPublisher{publish: publish}))
	return err
}

func graphicsOutcome(text string) (json.RawMessage, error) {
	var outcome struct {
		Value json.RawMessage     `json:"value"`
		Error *automation.Failure `json:"error"`
	}
	if err := json.Unmarshal([]byte(text), &outcome); err != nil {
		return nil, E.Cause(err, "graphics: decode the outcome")
	}
	if outcome.Error != nil {
		return nil, outcome.Error
	}
	return outcome.Value, nil
}

type GraphicsContext struct {
	call *automation.GraphicsCall
}

func (c *GraphicsContext) Tracing() bool {
	return c.call.Tracing()
}

func (c *GraphicsContext) Trace(name string, detail string, startedMs float64, durationMs float64) {
	c.call.Trace(time.UnixMilli(int64(startedMs)), name, detail, time.Duration(durationMs*float64(time.Millisecond)))
}

func (c *GraphicsContext) Cancelled() bool {
	return c.call.Context().Err() != nil
}

type GraphicsScreenshot struct {
	Image   []byte
	Scale   float64
	Failure string
}

func (c *GraphicsContext) Screenshot() *GraphicsScreenshot {
	data, scale, err := c.call.Screenshot()
	if err != nil {
		return &GraphicsScreenshot{Failure: automation.FailureOf(err)}
	}
	return &GraphicsScreenshot{Image: data, Scale: scale}
}

type GraphicsTimeline struct {
	watch *automation.TimelineWatch
}

func (c *GraphicsContext) WatchTimeline() *GraphicsTimeline {
	return &GraphicsTimeline{watch: c.call.WatchTimeline()}
}

func (t *GraphicsTimeline) Stop() string {
	data, err := json.Marshal(t.watch.Stop())
	if err != nil {
		return "[]"
	}
	return string(data)
}

type GraphicsPublisher struct {
	publish func(any)
}

func (p *GraphicsPublisher) Publish(value string) {
	p.publish(json.RawMessage(value))
}

type ScreenSink interface {
	OnPackets(batch []byte)
	OnEnd(failure string)
}

type ScreenFeed struct {
	feed *device.ScreenFeed
}

func (d *Device) OpenScreen(sink ScreenSink) (*ScreenFeed, error) {
	ctx, cancel := context.WithTimeout(context.Background(), screenOpenLimit)
	defer cancel()
	feed, err := d.connection.OpenScreen(ctx, sink.OnPackets, func(err error) { sink.OnEnd(automation.FailureOf(err)) })
	if err != nil {
		return nil, E.New(automation.FailureOf(err))
	}
	return &ScreenFeed{feed: feed}, nil
}

func (f *ScreenFeed) Info() string {
	data, _ := json.Marshal(f.feed.Info())
	return string(data)
}

func (f *ScreenFeed) RequestKeyFrame() {
	f.feed.RequestKeyFrame()
}

func (f *ScreenFeed) Close() {
	f.feed.Close()
}
