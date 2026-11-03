//go:build darwin && cgo

package computer

import (
	"context"
	"net"
	"slices"
	"strings"
	"unicode"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice"
	"github.com/swipt-automation/swipt/internal/coredevice/lockdown"
	"github.com/swipt-automation/swipt/internal/device"
	"github.com/swipt-automation/swipt/internal/log"
	"github.com/swipt-automation/swipt/internal/rfb"
	"github.com/swipt-automation/swipt/internal/usbmuxd"
)

const connectionUSB = "USB"

type pairedDevice struct {
	UDID string
	Name string
}

func listDevices(ctx context.Context) ([]pairedDevice, error) {
	devices, err := usbmuxd.ListDevices(ctx)
	if err != nil {
		return nil, err
	}
	var paired []pairedDevice
	for _, found := range preferUSB(devices) {
		value, err := lockdown.GetValue(ctx, dialer(found.ID), "DeviceName")
		if err != nil {
			if ctx.Err() != nil {
				return nil, err
			}
			continue
		}
		name, _ := value.(string)
		paired = append(paired, pairedDevice{UDID: found.UDID, Name: name})
	}
	return paired, nil
}

func preferUSB(devices []usbmuxd.Device) []usbmuxd.Device {
	var result []usbmuxd.Device
	for _, it := range devices {
		index := slices.IndexFunc(result, func(known usbmuxd.Device) bool { return known.UDID == it.UDID })
		switch {
		case index < 0:
			result = append(result, it)
		case it.Connection == connectionUSB:
			result[index] = it
		}
	}
	return result
}

func dialer(id uint64) lockdown.Dialer {
	return func(ctx context.Context, port uint16) (net.Conn, error) {
		return usbmuxd.Dial(ctx, id, port)
	}
}

func chooseDevice(ctx context.Context, given string) (pairedDevice, error) {
	devices, err := listDevices(ctx)
	if err != nil {
		return pairedDevice{}, err
	}
	if given != "" {
		devices = common.Filter(devices, func(it pairedDevice) bool {
			return strings.EqualFold(it.UDID, given) || strings.EqualFold(label(it.Name), label(given))
		})
	}
	switch len(devices) {
	case 1:
		return devices[0], nil
	case 0:
		if given != "" {
			return pairedDevice{}, E.New("no device named ", given, " is connected to this Mac")
		}
		return pairedDevice{}, E.New("no device is connected to this Mac")
	}
	names := common.Map(devices, func(it pairedDevice) string { return it.Name + " (" + it.UDID + ")" })
	return pairedDevice{}, E.New("more than one device is connected to this Mac: ", strings.Join(names, ", "), "; choose one with -d NAME|UDID")
}

func label(name string) string {
	var parts []string
	var part strings.Builder
	for _, character := range strings.NewReplacer("'", "", "’", "").Replace(name) {
		if character < unicode.MaxASCII && (unicode.IsLetter(character) || unicode.IsDigit(character)) {
			part.WriteRune(character)
			continue
		}
		if part.Len() > 0 {
			parts = append(parts, part.String())
			part.Reset()
		}
	}
	if part.Len() > 0 {
		parts = append(parts, part.String())
	}
	if len(parts) == 0 {
		return name
	}
	return strings.Join(parts, "-")
}

func connect(udid string, logger log.ContextLogger) func(ctx context.Context) (*coredevice.Device, error) {
	return func(ctx context.Context) (*coredevice.Device, error) {
		devices, err := usbmuxd.ListDevices(ctx)
		if err != nil {
			return nil, err
		}
		found := common.Find(preferUSB(devices), func(it usbmuxd.Device) bool { return it.UDID == udid })
		if found.ID == 0 {
			return nil, &device.Error{Problem: device.ProblemNoTunnel, Err: E.New("the device is not connected to this Mac")}
		}
		data, err := usbmuxd.ReadPairRecord(ctx, udid)
		if err != nil {
			return nil, E.Cause(err, "read the pair record")
		}
		record, err := lockdown.ParsePairRecord(data)
		if err != nil {
			return nil, err
		}
		logger.Debug("connecting through ", found.Connection, " as usbmuxd device ", found.ID)
		return coredevice.ConnectLockdown(ctx, coredevice.LockdownOptions{Record: record, Dial: dialer(found.ID), Logger: logger})
	}
}

type observer struct{}

func (observer) StateChanged(device.State, error) {}

func (observer) DeviceConnected(coredevice.DeviceInfo) {}

func (observer) ViewerConnected(*rfb.ServerSession) {}

func (observer) ViewerDisconnected(*rfb.ServerSession, error) {}

func (observer) StreamingChanged(bool) {}
