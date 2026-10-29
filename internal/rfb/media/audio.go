package media

const (
	// AVConference VCPayloadUtils returns 48000 Hz and 480 samples per frame
	// for payload 101, and the RemoteDesktopSystemAudio negotiator settings
	// use 2 channels (AVConference 2235.63.5.2, macOS 27.0.1 26A434, UUID
	// 93D8C8C0-8B9C-3A5E-A47D-01B5FAF73E1B,
	// +[VCPayloadUtils sampleRateForPayload:] 0x1c0eb35c4..0x1c0eb3638,
	// +[VCPayloadUtils codecSamplesPerFrameForPayload:blockSize:sampleRate:] 0x1c0eb38ac..0x1c0eb3908,
	// -[AVCMediaStreamNegotiatorSettingsRemoteDesktopSystemAudio audioChannelCount] 0x1c11b033c;
	// AVConference 2260.14.1, macOS 27.2 26B5101f, UUID
	// EDFB99EF-2F5E-35DD-8E63-089CBD102EFE,
	// +[VCPayloadUtils sampleRateForPayload:] 0x1c052dca4..0x1c052dd18,
	// +[VCPayloadUtils codecSamplesPerFrameForPayload:blockSize:sampleRate:] 0x1c052df8c..0x1c052dfe8,
	// -[AVCMediaStreamNegotiatorSettingsRemoteDesktopSystemAudio audioChannelCount] 0x1c082ca88).
	audioSampleRate = 48000
)
