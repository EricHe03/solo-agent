package deviceserver

import (
	"time"
)

func (s *Server) dismissScreenViewingNotifications(a *attachment) {
	for {
		client, err := a.accessibility.get(a.ctx)
		if err == nil {
			s.logger.Debug("watching screen-viewing notifications")
			for err == nil {
				var count int
				count, err = client.DismissScreenViewingNotifications(a.ctx)
				if count != 0 {
					s.logger.Debug("cleared screen-viewing notifications", "count", count)
				}
			}
		}
		if a.ctx.Err() != nil {
			return
		}
		s.logger.Warn("clear screen-viewing notifications", "error", err)
		select {
		case <-a.ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
}
