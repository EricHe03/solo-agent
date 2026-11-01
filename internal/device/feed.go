package device

import (
	"context"
	"encoding/binary"
	"maps"
	"slices"
	"sync"
	"time"

	"github.com/google/uuid"
	E "github.com/sagernet/sing/common/exceptions"

	"github.com/swipt-automation/swipt/internal/coredevice/display"
)

const (
	feedStartLimit    = 20 * time.Second
	feedStartAttempts = 3
	feedStableRun     = 10 * time.Second
	feedRetryDelay    = time.Second
	feedBatch         = 64
)

type ScreenInfo struct {
	Width  int     `json:"width"`
	Height int     `json:"height"`
	Scale  float64 `json:"scale"`
}

type ScreenFeed struct {
	feeds   *screenFeeds
	info    ScreenInfo
	deliver func(batch []byte)
	end     func(err error)
	release func()
}

type ownFeed struct {
	cancel context.CancelFunc
	stream *deviceStream
}

type screenFeeds struct {
	connection *Connection
	access     sync.Mutex
	open       map[*ScreenFeed]struct{}
	viewer     *videoSource
	own        *ownFeed
}

func newScreenFeeds(connection *Connection) *screenFeeds {
	return &screenFeeds{connection: connection, open: make(map[*ScreenFeed]struct{})}
}

func (s *Connection) OpenScreen(ctx context.Context, deliver func(batch []byte), end func(err error)) (*ScreenFeed, error) {
	c, release, err := s.acquire(ctx)
	if err != nil {
		return nil, err
	}
	displays, err := c.display.Displays(ctx)
	release()
	if err != nil {
		return nil, E.Cause(err, "read the device's displays")
	}
	primary, found := primaryDisplay(displays)
	if !found {
		return nil, E.New("the device lists no usable screen")
	}
	feed := &ScreenFeed{
		feeds:   s.feeds,
		info:    ScreenInfo{Width: primary.Width, Height: primary.Height, Scale: float64(max(primary.PointScale, 1))},
		deliver: deliver,
		end:     end,
		release: s.hold(),
	}
	s.feeds.add(feed)
	return feed, nil
}

func (f *ScreenFeed) Info() ScreenInfo {
	return f.info
}

func (f *ScreenFeed) RequestKeyFrame() {
	f.feeds.requestKeyFrame()
}

func (f *ScreenFeed) Close() {
	f.feeds.remove(f)
	f.release()
}

func (f *screenFeeds) add(feed *ScreenFeed) {
	f.access.Lock()
	defer f.access.Unlock()
	f.open[feed] = struct{}{}
	switch {
	case f.viewer != nil:
		_ = f.viewer.RequestKeyFrame()
	case f.own == nil:
		f.startLocked()
	case f.own.stream != nil:
		_ = f.own.stream.stream.RequestKeyFrame()
	}
}

func (f *screenFeeds) remove(feed *ScreenFeed) {
	f.access.Lock()
	defer f.access.Unlock()
	delete(f.open, feed)
	if len(f.open) == 0 && f.own != nil {
		f.own.cancel()
		f.own = nil
	}
}

func (f *screenFeeds) startLocked() {
	ctx, cancel := context.WithCancel(f.connection.ctx)
	own := &ownFeed{cancel: cancel}
	f.own = own
	go f.run(ctx, own)
}

func (f *screenFeeds) requestKeyFrame() {
	f.access.Lock()
	defer f.access.Unlock()
	switch {
	case f.viewer != nil:
		_ = f.viewer.RequestKeyFrame()
	case f.own != nil && f.own.stream != nil:
		_ = f.own.stream.stream.RequestKeyFrame()
	}
}

func (f *screenFeeds) viewerStarted(v *videoSource) {
	f.access.Lock()
	defer f.access.Unlock()
	f.viewer = v
}

func (f *screenFeeds) viewerStopped(v *videoSource) {
	f.access.Lock()
	defer f.access.Unlock()
	if f.viewer != v {
		return
	}
	f.viewer = nil
	if len(f.open) > 0 && f.own == nil {
		f.startLocked()
	}
}

func (f *screenFeeds) viewerTaken() bool {
	f.access.Lock()
	defer f.access.Unlock()
	return f.viewer != nil
}

func (f *screenFeeds) tapping(v *videoSource) bool {
	f.access.Lock()
	defer f.access.Unlock()
	return f.viewer == v && len(f.open) > 0
}

func (f *screenFeeds) run(ctx context.Context, own *ownFeed) {
	defer func() {
		f.access.Lock()
		if f.own == own {
			f.own = nil
		}
		f.access.Unlock()
		own.cancel()
	}()
	failures := 0
	for ctx.Err() == nil {
		started := time.Now()
		stream, err := f.connection.startFeedStream(ctx)
		if stream == nil && err == nil {
			return
		}
		if err == nil {
			f.access.Lock()
			own.stream = stream
			f.access.Unlock()
			err = f.read(ctx, own, stream)
			f.access.Lock()
			own.stream = nil
			f.access.Unlock()
			f.connection.streams.retire(stream)
		}
		if ctx.Err() != nil || f.viewerTaken() {
			return
		}
		if time.Since(started) >= feedStableRun {
			failures = 0
		}
		failures++
		if failures >= feedStartAttempts {
			f.fail(own, err)
			return
		}
		f.connection.logger.Debug(E.Cause(err, "the screen feed stopped; restarting it"))
		if sleep(ctx, feedRetryDelay) != nil {
			return
		}
	}
}

func (f *screenFeeds) fail(own *ownFeed, err error) {
	f.access.Lock()
	if f.own != own {
		f.access.Unlock()
		return
	}
	feeds := f.open
	f.open = make(map[*ScreenFeed]struct{})
	f.own = nil
	f.access.Unlock()
	for feed := range feeds {
		feed.end(err)
		feed.release()
	}
}

func (f *screenFeeds) read(ctx context.Context, own *ownFeed, stream *deviceStream) error {
	packets := make([]display.Packet, feedBatch)
	for {
		readContext, cancel := context.WithTimeoutCause(ctx, silenceLimit, errVideoSilent)
		n, err := stream.stream.ReadPackets(readContext, packets)
		cancel()
		if err != nil {
			return err
		}
		var batch []byte
		for _, packet := range packets[:n] {
			batch = appendFeedRecord(batch, packet.Buffer.Bytes(), packet.RTCP, packet.Arrival)
			packet.Buffer.Release()
		}
		f.deliver(batch, func() bool { return f.own == own })
	}
}

func (f *screenFeeds) deliver(batch []byte, current func() bool) {
	f.access.Lock()
	if !current() {
		f.access.Unlock()
		return
	}
	feeds := slices.Collect(maps.Keys(f.open))
	f.access.Unlock()
	for _, feed := range feeds {
		feed.deliver(batch)
	}
}

func appendFeedRecord(batch []byte, data []byte, rtcp bool, arrival time.Time) []byte {
	batch = binary.BigEndian.AppendUint64(batch, uint64(arrival.UnixNano()))
	flag := byte(0)
	if rtcp {
		flag = 1
	}
	batch = append(batch, flag)
	batch = binary.BigEndian.AppendUint32(batch, uint32(len(data)))
	return append(batch, data...)
}

func (s *Connection) startFeedStream(ctx context.Context) (*deviceStream, error) {
	ctx, cancel := context.WithTimeout(ctx, feedStartLimit)
	defer cancel()
	a, release, err := s.acquire(ctx)
	if err != nil {
		return nil, err
	}
	release()
	m := s.streams
	if err = m.acquire(ctx); err != nil {
		return nil, err
	}
	defer m.release()
	if s.feeds.viewerTaken() {
		return nil, nil
	}
	m.retireAll()
	if err = sleep(ctx, m.startDelay()); err != nil {
		return nil, err
	}
	m.access.Lock()
	m.lastStart = time.Now()
	m.access.Unlock()
	video, err := a.display.StartVideo(ctx, display.StreamOptions{SessionID: uuid.New(), Mode: display.ModeRemoteDesktop})
	if err != nil {
		m.access.Lock()
		m.failures++
		m.access.Unlock()
		return nil, E.Cause(err, "start the device's video")
	}
	stream := &deviceStream{ctx: a.owner, device: a.device, stream: video}
	m.access.Lock()
	m.failures = 0
	m.open[stream] = struct{}{}
	m.remote[stream] = struct{}{}
	m.access.Unlock()
	_ = video.RequestKeyFrame()
	return stream, nil
}
