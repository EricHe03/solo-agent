package instproxy

import (
	"fmt"
	"net"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/rsd"
)

const (
	Service = "com.apple.mobile.installation_proxy"

	statusComplete = "Complete"
)

// A command answers with status messages until Status is Complete or Error is
// set (go-ios 6910f3b, ios/installationproxy/installationproxy.go:111, 169-173).
func run(conn net.Conn, command map[string]any) error {
	plist := rsd.NewPlistConn(conn)
	err := plist.Send(command)
	if err != nil {
		return err
	}
	for {
		reply, err := plist.Receive()
		if err != nil {
			return err
		}
		if failure, failed := reply["Error"]; failed {
			return E.New(fmt.Sprint(failure), ": ", fmt.Sprint(reply["ErrorDescription"]))
		}
		if reply["Status"] == statusComplete {
			return nil
		}
	}
}

func Install(conn net.Conn, packagePath, bundleID string) error {
	err := run(conn, map[string]any{
		"Command":       "Install",
		"PackagePath":   packagePath,
		"ClientOptions": map[string]any{"CFBundleIdentifier": bundleID, "PackageType": "Developer"},
	})
	if err != nil {
		return E.Cause(err, "instproxy: install ", bundleID)
	}
	return nil
}
