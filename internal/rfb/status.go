package rfb

type Status uint16

// Apple's viewer handles status commands 1 through 17 in a jump table, logging
// "user paused connection" for 7 and "user resumed connection" for 8 (ScreenSharing 776.27,
// macOS 27.0.1 26A434, UUID EC0B2C20-F816-3FCE-822D-F9403C09EB50,
// _HandleServerMessage 0x1cc062684..0x1cc0626b0, 0x1cc063728, 0x1cc063488;
// table 0x1cc06455c).
const (
	StatusPasteboardChanged Status = 2
)
