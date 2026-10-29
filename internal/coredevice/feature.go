package coredevice

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/google/uuid"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/xpc"
)

type FeatureError struct {
	Feature string
	Code    int64
	chain   []string
	causes  []featureCause
}

type featureCause struct {
	domain string
	code   int64
}

func (e *FeatureError) Error() string {
	return e.Feature + ": " + strings.Join(e.chain, ": ")
}

func (e *FeatureError) CausedBy(domain string, code int64) bool {
	return slices.Contains(e.causes, featureCause{domain, code})
}

// pymobiledevice3 uses CoreDevice 629.3 and DDI protocol 2 (pymobiledevice3
// 1146717, pymobiledevice3/remote/core_device/core_device_service.py:10-19, 78-79).
var coreDeviceVersion = map[string]any{
	"components":              []any{uint64(629), uint64(3)},
	"originalComponentsCount": int64(2),
	"stringValue":             "629.3",
}

func FeatureRequest(deviceIdentifier, feature, action string, input map[string]any) map[string]any {
	request := map[string]any{
		"CoreDevice.CoreDeviceDDIProtocolVersion": int64(2),
		"CoreDevice.action":                       map[string]any{},
		"CoreDevice.coreDeviceVersion":            coreDeviceVersion,
		"CoreDevice.deviceIdentifier":             deviceIdentifier,
		"CoreDevice.featureIdentifier":            feature,
		"CoreDevice.input":                        input,
		"CoreDevice.invocationIdentifier":         uuid.NewString(),
	}
	if action != "" {
		request["CoreDevice.actionIdentifier"] = action
	}
	return request
}

func InvokeFeature(ctx context.Context, conn *xpc.Conn, deviceIdentifier, feature, action string, input map[string]any) (map[string]any, error) {
	reply, err := conn.Request(ctx, FeatureRequest(deviceIdentifier, feature, action, input))
	if ctx.Err() != nil {
		err = context.Cause(ctx)
	}
	if err != nil {
		return nil, E.Cause(err, feature)
	}
	return FeatureOutput(feature, reply)
}

// Launching com.apple.ActivityMessagesApp failed with CoreDeviceError 10002,
// "The application failed to launch." (DDI 27B5028f CoreDeviceUtilities
// 0x1aa85c); only its NSUnderlyingError chain names
// FBSOpenApplicationServiceErrorDomain 1 and FBSOpenApplicationErrorDomain 4
// (iPhone18,2, iOS 27.2 24B115).
func FeatureOutput(feature string, reply map[string]any) (map[string]any, error) {
	if output, isDictionary := reply["CoreDevice.output"].(map[string]any); isDictionary {
		return output, nil
	}
	nsError, isDictionary := reply["CoreDevice.error"].(map[string]any)
	if !isDictionary {
		return nil, E.New(feature, ": unexpected reply: ", fmt.Sprint(reply))
	}
	result := &FeatureError{Feature: feature}
	for nsError != nil {
		var code int64
		switch number := nsError["code"].(type) {
		case int64:
			code = number
		case uint64:
			code = int64(number)
		}
		if result.chain == nil {
			result.Code = code
		}
		domain, _ := nsError["domain"].(string)
		userInfo, _ := nsError["userInfo"].(map[string]any)
		description, _ := userInfo["NSLocalizedDescription"].(string)
		if description == "" {
			description, _ = userInfo["NSDebugDescription"].(string)
		}
		text := domain + " " + strconv.FormatInt(code, 10)
		if description != "" {
			text = description + " (" + text + ")"
		}
		result.chain = append(result.chain, text)
		result.causes = append(result.causes, featureCause{domain, code})
		nsError, _ = userInfo["NSUnderlyingError"].(map[string]any)
	}
	return nil, result
}
