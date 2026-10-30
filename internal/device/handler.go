package device

import (
	"context"

	"github.com/swipt-automation/swipt/internal/rfb"
	"github.com/swipt-automation/swipt/internal/rfb/media"
)

type viewerHandler Connection

func (h *viewerHandler) connection() *Connection {
	return (*Connection)(h)
}

func (h *viewerHandler) Screen(ctx context.Context) (rfb.ServerScreen, error) {
	s := h.connection()
	_, release, err := s.acquire(ctx)
	if err != nil {
		return rfb.ServerScreen{}, err
	}
	release()
	s.access.Lock()
	defer s.access.Unlock()
	return s.screen, nil
}

func (h *viewerHandler) SessionStarted(session *rfb.ServerSession) {
	s := h.connection()
	release := s.hold()
	context.AfterFunc(session.Context(), release)
	s.notify(func(observer Observer) { observer.ViewerConnected(session) })
	s.input.viewerConnected(session)
}

func (h *viewerHandler) SessionEnded(session *rfb.ServerSession, err error) {
	s := h.connection()
	s.input.sessionEnded(session)
	s.clip.sharing(session, false)
	s.notify(func(observer Observer) { observer.ViewerDisconnected(session, err) })
}

func (h *viewerHandler) HandleEvent(session *rfb.ServerSession, event rfb.ViewerEvent) {
	s := h.connection()
	switch event := event.(type) {
	case rfb.ViewerPointer, rfb.ViewerKey, rfb.ViewerScroll, rfb.ViewerGesture, rfb.ViewerSystemCommand:
		s.input.post(session, event)
	case rfb.ViewerMode:
		if event.Mode == rfb.ModeObserve {
			s.input.sessionEnded(session)
		} else {
			s.input.sessionResumed(session)
		}
	case rfb.ViewerClipboard:
		s.clip.viewerClipboard(event.Clipboard)
	case rfb.ViewerClipboardSharing:
		s.clip.sharing(session, event.Enabled)
	}
}

func (h *viewerHandler) Clipboard(ctx context.Context) (*rfb.Clipboard, error) {
	return h.connection().clip.read(ctx)
}

func (h *viewerHandler) OpenVideo(ctx context.Context, request media.ServerVideoRequest) (media.ServerVideoSource, error) {
	return h.connection().openVideo(ctx, request)
}

func (h *viewerHandler) OpenAudio() (media.ServerAudioSource, error) {
	return h.connection().openAudio()
}
