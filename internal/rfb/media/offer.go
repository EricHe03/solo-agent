package media

import (
	"fmt"
	"time"
)

const (

	// ScreenSharing copies 46 bytes for each negotiated SRTP key
	// (ScreenSharing 776.27, macOS 27.0.1 26A434, UUID
	// EC0B2C20-F816-3FCE-822D-F9403C09EB50,
	// _RFBMediaStreamServerConfiguration 0x1cc14a08c..0x1cc14a100;
	// ScreenSharing 786.3, macOS 27.2 26B5101f, UUID
	// 21DF7A41-0D38-3DF3-B87A-8A6249686735,
	// _RFBMediaStreamServerConfiguration 0x22e58d688..0x22e58d6fc).
	masterKeyLength = 46

	negotiatorModeCoreDeviceScreenSharing    = 5
	negotiatorModeRemoteDesktopScreenSharing = 7
	negotiatorModeRemoteDesktopSystemAudio   = 8
	negotiatorModeNearbyScreenSharing        = 9

	hdrModeStandard = 0

	messageFlagFrameRate60 = 1 << 0

	// AVConference writes blob version 2 and user agent "Viceroy 1.7.0" into
	// both offer and answer blobs (AVConference 2235.63.5.2, macOS 27.0.1
	// 26A434, UUID 93D8C8C0-8B9C-3A5E-A47D-01B5FAF73E1B,
	// -[VCMediaNegotiator negotiationData] 0x1c122bdd4..0x1c122bde8,
	// -[VCMediaNegotiator newResponseBlob] 0x1c122d41c..0x1c122d430;
	// AVConference 2260.14.1, macOS 27.2 26B5101f, UUID
	// EDFB99EF-2F5E-35DD-8E63-089CBD102EFE,
	// -[VCMediaNegotiator negotiationData] 0x1c089eb0c..0x1c089eb20,
	// -[VCMediaNegotiator newResponseBlob] 0x1c08a0154..0x1c08a0168).
	negotiatorUserAgent   = "Viceroy 1.7.0"
	negotiatorBlobVersion = 2

	// Native AVConference mode-7 offers use transport 1, operations 1/2 and
	// format bitmap 0xc3c3, and add the display-dependent AR/XR after these
	// codec FLS prefixes. VideoProcessing builds the two prefixes
	// (VideoProcessing 1395.65.1, macOS 27.0.1 26A434, UUID
	// D87079FD-5315-32B1-8022-E6144A69A8EE,
	// _VCPCodecCopyProperties 0x1b4fdf4c4..0x1b4fdf4d8;
	// VideoProcessing 1415.6.1, macOS 27.2 26B5101f, UUID
	// A6FC3A01-8834-335F-A877-FDACE2E1AECC,
	// _VCPCodecCopyProperties 0x1cb6084f0..0x1cb608504).
	videoRuleTransport       = 1
	videoRuleOperationEncode = 1
	videoRuleOperationDecode = 2

	parameterSetsHEVC = 14

	endpointClientVersion = 1
)

// AVConference maps modes 5/7/9 to CoreDeviceScreenSharing, RemoteDesktopScreenSharing,
// and NearbyScreenSharing settings (AVConference 2235.63.5.2, macOS 27.0.1 26A434,
// UUID 93D8C8C0-8B9C-3A5E-A47D-01B5FAF73E1B,
// +[AVCMediaStreamNegotiatorSettings negotiatorSettingsForMode:deviceRole:options:errorString:] 0x1c11af820..0x1c11af8e0,
// class table 0x1e1c9b9f0; AVConference 2260.14.1, macOS 27.2 26B5101f, UUID
// EDFB99EF-2F5E-35DD-8E63-089CBD102EFE,
// +[AVCMediaStreamNegotiatorSettings negotiatorSettingsForMode:deviceRole:options:errorString:] 0x1c082bf6c..0x1c082c02c,
// class table 0x1e18e2f80).
type VideoMode int

const (
	VideoModeAutomatic     VideoMode = 0
	VideoModeCoreDevice    VideoMode = negotiatorModeCoreDeviceScreenSharing
	VideoModeRemoteDesktop VideoMode = negotiatorModeRemoteDesktopScreenSharing
	VideoModeNearby        VideoMode = negotiatorModeNearbyScreenSharing
)

func (m VideoMode) String() string {
	switch m {
	case VideoModeAutomatic:
		return "automatic"
	case VideoModeCoreDevice:
		return "CoreDevice"
	case VideoModeRemoteDesktop:
		return "RemoteDesktop"
	case VideoModeNearby:
		return "Nearby"
	default:
		return fmt.Sprint("mode(", int(m), ")")
	}
}

type PixelFormats uint32

const (
	PixelFormat420FullRange  PixelFormats = 1 << 0
	PixelFormat420VideoRange PixelFormats = 1 << 1
	PixelFormat444FullRange  PixelFormats = 1 << 3
	PixelFormat444VideoRange PixelFormats = 1 << 4
)

func ntpTime(t time.Time) uint64 {
	const secondsFrom1900To1970 = 2208988800
	seconds := uint64(t.Unix() + secondsFrom1900To1970)
	fraction := uint64(t.Nanosecond()) << 32 / 1_000_000_000
	return seconds<<32 | fraction
}
