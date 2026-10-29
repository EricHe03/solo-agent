package deviceserver

import (
	"context"
	"strings"
	"sync"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
)

type remoteAccessibility struct {
	attachment *attachment
	logger     logger.ContextLogger
	access     sync.Mutex
	client     *accessibility.RemoteClient
	dialing    chan struct{}
	dialErr    error
	pushed     func(accessibility.Push)
	restarted  sync.Once
}

func (r *remoteAccessibility) get(ctx context.Context) (*accessibility.RemoteClient, error) {
	a := r.attachment
	for {
		r.access.Lock()
		if a.ctx.Err() != nil {
			r.access.Unlock()
			return nil, E.New("the device is not connected")
		}
		if r.client != nil && r.client.Err() == nil {
			client := r.client
			r.access.Unlock()
			return client, nil
		}
		dialing := r.dialing
		if dialing == nil {
			dialing = make(chan struct{})
			r.dialing = dialing
			go r.dial(dialing, r.client)
			r.client = nil
		}
		r.access.Unlock()
		select {
		case <-dialing:
		case <-ctx.Done():
			return nil, E.Cause(ctx.Err(), "connect to the accessibility service")
		}
		r.access.Lock()
		err := r.dialErr
		r.access.Unlock()
		if err != nil {
			return nil, err
		}
	}
}

func (r *remoteAccessibility) dial(done chan struct{}, broken *accessibility.RemoteClient) {
	a := r.attachment
	if broken != nil {
		if err := broken.Close(); err != nil {
			r.logger.Debug(E.Cause(err, "close remote AX"))
		}
	}
	r.restarted.Do(func() {
		if err := r.restart(a.ctx); err != nil {
			r.logger.Debug(E.Cause(err, "restart axauditd"))
		}
	})
	client, err := accessibility.DialRemote(a.ctx, a.owner, a.device, r.pushed)
	r.access.Lock()
	r.client, r.dialErr, r.dialing = client, err, nil
	r.access.Unlock()
	close(done)
}

func (r *remoteAccessibility) reopen(ctx context.Context, stalled *accessibility.RemoteClient) error {
	if stalled == nil {
		r.access.Lock()
		stalled = r.client
		r.access.Unlock()
	}
	if stalled != nil {
		if err := stalled.Close(); err != nil {
			r.logger.Debug(E.Cause(err, "close stalled remote AX"))
		}
	}
	_, err := r.get(ctx)
	return err
}

func (r *remoteAccessibility) restart(ctx context.Context) error {
	processes, err := apps.Processes(ctx, r.attachment.device)
	if err != nil {
		return err
	}
	daemon := common.Find(processes, func(it apps.Process) bool {
		return strings.HasSuffix(it.Executable, "/AccessibilityAudit.framework/Support/axauditd")
	})
	if daemon.PID == 0 {
		return E.New("axauditd is not running")
	}
	return apps.Kill(ctx, r.attachment.device, daemon.PID)
}

func (r *remoteAccessibility) close() error {
	r.access.Lock()
	dialing := r.dialing
	r.access.Unlock()
	if dialing != nil {
		<-dialing
	}
	r.access.Lock()
	client := r.client
	r.client = nil
	r.access.Unlock()
	if client == nil {
		return nil
	}
	if err := client.Close(); err != nil {
		return E.Cause(err, "close remote AX")
	}
	return nil
}
