package display

import (
	"errors"

	"github.com/swipt-automation/swipt/internal/coredevice"
)

// CoreDeviceError mediaStreamNotSupportedOnDevice is 9021 and
// mediaStreamSensorInUse is 9022 (DDI 27B5028f CoreDeviceUtilities 0x1b21e4,
// 0x1b1884).
const (
	ErrorCodeUnsupported = 9021
	ErrorCodeMediaInUse  = 9022
)

func IsMediaInUse(err error) bool {
	featureError, isFeatureError := errors.AsType[*coredevice.FeatureError](err)
	return isFeatureError && featureError.Code == ErrorCodeMediaInUse
}

func IsUnsupported(err error) bool {
	featureError, isFeatureError := errors.AsType[*coredevice.FeatureError](err)
	return isFeatureError && featureError.Code == ErrorCodeUnsupported
}
