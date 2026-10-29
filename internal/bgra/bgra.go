package bgra

type Cursor struct {
	Width    int
	Height   int
	HotspotX int
	HotspotY int
	Pixels   []byte
	Invert   []byte
}
