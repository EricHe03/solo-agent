package deviceserver

import (
	"context"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/coredevice/hid"
	"github.com/swipt-automation/swipt/internal/coredevice/instruments"
	"github.com/swipt-automation/swipt/internal/coredevice/pasteboard"
)

const (
	phoneDeviceWait   = 5 * time.Second
	phoneGeometryLife = time.Second
	phoneEdgeRegion   = 4.0
)

type Point struct {
	X, Y float64
}

type Rect struct {
	X, Y, Width, Height float64
}

func (r Rect) Center() Point {
	return Point{r.X + r.Width/2, r.Y + r.Height/2}
}

func (r Rect) Contains(at Point) bool {
	return at.X >= r.X && at.X <= r.X+r.Width && at.Y >= r.Y && at.Y <= r.Y+r.Height
}

func (r Rect) Intersect(other Rect) Rect {
	x, y := max(r.X, other.X), max(r.Y, other.Y)
	return Rect{x, y, max(min(r.X+r.Width, other.X+other.Width)-x, 0), max(min(r.Y+r.Height, other.Y+other.Height)-y, 0)}
}

func (r Rect) Empty() bool {
	return r.Width <= 0 || r.Height <= 0
}

func (r Rect) area() float64 {
	return r.Width * r.Height
}

func (r Rect) subtract(cut Rect) []Rect {
	overlap := r.Intersect(cut)
	if overlap.Empty() {
		return []Rect{r}
	}
	parts := []Rect{
		{r.X, r.Y, r.Width, overlap.Y - r.Y},
		{r.X, overlap.Y + overlap.Height, r.Width, r.Y + r.Height - overlap.Y - overlap.Height},
		{r.X, overlap.Y, overlap.X - r.X, overlap.Height},
		{overlap.X + overlap.Width, overlap.Y, r.X + r.Width - overlap.X - overlap.Width, overlap.Height},
	}
	return common.Filter(parts, func(part Rect) bool { return part.Width >= 1 && part.Height >= 1 })
}

type PhoneScreen struct {
	Width, Height float64
	Scale         float64
	Orientation   string
}

type Phone struct {
	server *Server
	logger logger.ContextLogger

	access          sync.Mutex
	input           *hid.Client
	lockState       lockStateReader
	geometryAccess  sync.Mutex
	geometry        phoneGeometry
	geometryAt      time.Time
	springboard     atomic.Uint64
	frontAccess     sync.Mutex
	front           frontApplication
	frontGeneration atomic.Uint64
	location        *instruments.Location
	recordAccess    sync.Mutex
	recordings      map[*Recording]struct{}
}

func (s *Server) Phone() *Phone {
	return s.phone
}

func (p *Phone) begin(ctx context.Context) (*attachment, context.Context, context.CancelFunc, error) {
	waitContext, cancelWait := context.WithTimeout(ctx, phoneDeviceWait)
	a, err := p.server.waitDevice(waitContext)
	cancelWait()
	if err != nil {
		return nil, nil, nil, err
	}
	operation, cancel := inputContext(a, ctx)
	return a, operation, cancel, nil
}

func (p *Phone) close() error {
	p.access.Lock()
	defer p.access.Unlock()
	p.geometryAccess.Lock()
	p.geometryAt = time.Time{}
	p.geometryAccess.Unlock()
	p.springboard.Store(0)
	p.forgetFront()
	p.closeLocation()
	return E.Errors(p.closeInput(), p.lockState.close())
}

func (p *Phone) closeInput() error {
	if p.input == nil {
		return nil
	}
	err := p.input.Close()
	p.input = nil
	return err
}

func (p *Phone) withInput(a *attachment, send func(*hid.Client) error) error {
	if p.input == nil {
		p.input = hid.New(a.owner, a.device, p.logger, hid.SoftwareKeyboard)
	}
	err := send(p.input)
	if err != nil {
		return E.Append(err, p.closeInput(), func(err error) error { return E.Cause(err, "close the device input") })
	}
	return nil
}

func (p *Phone) withAccessibility(ctx context.Context, a *attachment, read bool, call func(*accessibility.RemoteClient) error) error {
	client, err := a.accessibility.get(ctx)
	if err != nil {
		return p.restartStalled(ctx, a, read, err)
	}
	return p.reopenStalled(ctx, a, client, read, call(client))
}

func (p *Phone) reopenStalled(ctx context.Context, a *attachment, stalled *accessibility.RemoteClient, read bool, err error) error {
	if !errors.Is(err, accessibility.ErrStalled) {
		return err
	}
	p.forgetFront()
	p.logger.Warn("reopen remote AX: ", err)
	err = a.accessibility.reopen(ctx, stalled)
	if err == nil {
		if read {
			return E.New("the connection to the device's accessibility service stopped answering and was reopened; the elements found before still hold")
		}
		return E.New("the connection to the device's accessibility service stopped answering an action, which it may have performed, and was reopened; the elements found before still hold")
	}
	return p.restartStalled(ctx, a, read, err)
}

func (p *Phone) restartStalled(ctx context.Context, a *attachment, read bool, err error) error {
	if !errors.Is(err, accessibility.ErrStalled) {
		return err
	}
	p.forgetFront()
	p.logger.Warn("restart axauditd: ", err)
	if restartErr := a.accessibility.restart(ctx); restartErr != nil {
		return E.Cause(restartErr, "restart the stalled accessibility service")
	}
	if read {
		return E.New("the device's accessibility service stopped answering and was restarted; the elements found before are gone, find them again in a new phone.screen()")
	}
	return E.New("the device's accessibility service stopped answering an action, which it may have performed, and was restarted; the elements found before are gone, find them again in a new phone.screen()")
}

type phoneGeometry struct {
	PhoneScreen
	turns int
}

func (p *Phone) readGeometry(ctx context.Context, a *attachment) (phoneGeometry, error) {
	p.geometryAccess.Lock()
	defer p.geometryAccess.Unlock()
	if time.Since(p.geometryAt) < phoneGeometryLife {
		return p.geometry, nil
	}
	displays, err := a.display.Displays(ctx)
	if err != nil {
		return phoneGeometry{}, E.Cause(err, "read the device's displays")
	}
	primary, found := primaryDisplay(displays)
	if !found {
		return phoneGeometry{}, E.New("the device lists no usable screen")
	}
	p.server.updateDisplay(primary)
	scale := float64(max(primary.PointScale, 1))
	turns := orientationTurns(primary.CurrentOrientation)
	width, height := primary.Width, primary.Height
	if turns%2 == 1 {
		width, height = height, width
	}
	touch := touchTurns(geometryOf(primary), width, height)
	orientation := "portrait"
	switch {
	case width > height:
		orientation = "landscape"
	case turns == 2:
		orientation = "portraitUpsideDown"
	}
	p.geometry = phoneGeometry{
		PhoneScreen: PhoneScreen{Width: float64(width) / scale, Height: float64(height) / scale, Scale: scale, Orientation: orientation},
		turns:       touch,
	}
	p.geometryAt = time.Now()
	return p.geometry, nil
}

func (g phoneGeometry) check(at Point) error {
	if at.X < 0 || at.X > g.Width || at.Y < 0 || at.Y > g.Height {
		return E.New("the point [", at.X, ", ", at.Y, "] is outside the ", g.Width, "x", g.Height, " screen")
	}
	return nil
}

func (g phoneGeometry) touch(at Point) hid.Touch {
	u := clamp(at.X/g.Width, 0, 1)
	v := clamp(at.Y/g.Height, 0, 1)
	for range g.turns {
		u, v = v, 1-u
	}
	return hid.Touch{X: u, Y: v}
}

// The system-wide hit test takes a point in the digitizer's orientation:
// (834 − y, x) in landscape (iPad17,1, iPadOS 27.2 24B115).
func (g phoneGeometry) digitizer(at Point) accessibility.LayoutPoint {
	touch := g.touch(at)
	width, height := g.Width, g.Height
	if g.turns%2 == 1 {
		width, height = height, width
	}
	return accessibility.LayoutPoint{X: touch.X * width, Y: touch.Y * height}
}

func (g phoneGeometry) edge(at Point) hid.Edge {
	distances := [4]float64{at.Y, g.Width - at.X, g.Height - at.Y, at.X}
	nearest := -1
	for side, distance := range distances {
		if distance <= phoneEdgeRegion && (nearest < 0 || distance < distances[nearest]) {
			nearest = side
		}
	}
	if nearest < 0 {
		return hid.EdgeNone
	}
	edges := [4]hid.Edge{hid.EdgeTop, hid.EdgeRight, hid.EdgeBottom, hid.EdgeLeft}
	return edges[(nearest-g.turns)&3]
}

// An application that keeps the interface orientation reports its frames in
// it; SpringBoard's windows report theirs in the digitizer's space whatever
// the orientation, and that space is portrait on an iPad whose display is
// landscape native (iPad17,1, iPadOS 27.2 24B115; iPhone18,2, iOS 27.2
// 24B5110a). Some of SpringBoard's windows report their frames and those of
// their contents in pixels (iPhone18,2, iOS 27.2 24B115).
type axSpace struct {
	geometry      phoneGeometry
	rotated       bool
	width, height float64
	pid, context  uint64
}

func spaceOf(geometry phoneGeometry, app accessibility.Element) axSpace {
	return axSpace{geometry: geometry, pid: app.Ref.PID, context: app.Context}.window(app.Frame)
}

func (s axSpace) window(frame *accessibility.LayoutFrame) axSpace {
	out := s
	out.rotated, out.width, out.height = false, 0, 0
	if frame == nil || frame.Width <= 0 || frame.Height <= 0 {
		return out
	}
	switch {
	case (frame.Width > frame.Height) != (s.geometry.Width > s.geometry.Height):
		out.rotated, out.width, out.height = true, frame.Width, frame.Height
	case math.Abs(frame.Width-s.geometry.Width*s.geometry.Scale) < 1 && math.Abs(frame.Height-s.geometry.Height*s.geometry.Scale) < 1:
		out.width, out.height = frame.Width, frame.Height
	}
	return out
}

func (s axSpace) point(at accessibility.LayoutPoint) Point {
	if s.width == 0 {
		return Point{at.X, at.Y}
	}
	u, v := at.X/s.width, at.Y/s.height
	if s.rotated {
		for range s.geometry.turns {
			u, v = 1-v, u
		}
	}
	return Point{u * s.geometry.Width, v * s.geometry.Height}
}

func (s axSpace) rect(frame accessibility.LayoutFrame) Rect {
	first := s.point(accessibility.LayoutPoint{X: frame.X, Y: frame.Y})
	second := s.point(accessibility.LayoutPoint{X: frame.X + frame.Width, Y: frame.Y + frame.Height})
	return Rect{X: min(first.X, second.X), Y: min(first.Y, second.Y), Width: math.Abs(second.X - first.X), Height: math.Abs(second.Y - first.Y)}
}

// A widget or Live Activity has a render context of its own, placed on the
// screen at an offset the translator does not report; web content reports
// none and is in the application's space (iPhone18,2, iOS 27.2 24B5110a).
func (s axSpace) remote(element accessibility.Element) bool {
	return s.context != 0 && element.Context != 0 && element.Ref.PID != s.pid && element.Context != s.context
}

type PhoneNode struct {
	AX       accessibility.Element
	Frame    Rect
	Visible  Rect
	Point    Point
	Covered  bool
	Inert    bool
	Remote   bool
	Web      bool
	Focused  bool
	Clip     Rect
	Children []*PhoneNode
	Parent   *PhoneNode

	model *PhoneModel
}

func (n *PhoneNode) HasFrame() bool {
	return n.AX.Frame != nil && !n.Remote
}

func (n *PhoneNode) Shown() bool {
	return n.HasFrame() && !n.Visible.Empty()
}

func (n *PhoneNode) Contains(other *PhoneNode) bool {
	for ; other != nil; other = other.Parent {
		if other == n {
			return true
		}
	}
	return false
}

type PhoneModel struct {
	BundleID string
	Root     *PhoneNode
	System   *PhoneNode

	nodes map[accessibility.ElementRef]*PhoneNode
}

func (m *PhoneModel) Node(ref accessibility.ElementRef) *PhoneNode {
	return m.nodes[ref]
}

// SpringBoard lists elements with no area and drops them again while the
// screen stays still (iPhone18,2, iOS 27.2 24B115).
func signature(roots ...*PhoneNode) string {
	var out strings.Builder
	for _, root := range roots {
		if root != nil {
			walkNodes(root, func(node *PhoneNode) {
				if node.Shown() {
					fmt.Fprintf(&out, "%d:%d@%v|%s|%s|%t\n", node.AX.Ref.PID, node.AX.Ref.ObjectID, node.Frame, node.AX.Label, node.AX.Value, node.Inert)
				}
			})
		}
	}
	return out.String()
}

func walkNodes(root *PhoneNode, visit func(node *PhoneNode)) {
	visit(root)
	for _, child := range root.Children {
		walkNodes(child, visit)
	}
}

// Automation types that XCTest converts to XCUIElementTypeWindow,
// XCUIElementTypeKeyboard and XCUIElementTypeStatusBar (Xcode 27.1 27A9275
// XCTAutomationSupport _XCTElementTypeFromAXAutomationType 0x1e444, table
// 0x46e28).
const (
	windowAutomationType    = 2
	keyboardAutomationType  = 19
	statusBarAutomationType = 25
)

func modelOf(geometry phoneGeometry, screen *accessibility.Screen) *PhoneModel {
	model := &PhoneModel{BundleID: screen.BundleID, nodes: make(map[accessibility.ElementRef]*PhoneNode)}
	model.Root = model.convert(spaceOf(geometry, screen.Root.Element), screen.Root, nil, screen.Focused)
	if screen.System != nil {
		model.System = model.convert(spaceOf(geometry, screen.System.Element), screen.System, nil, nil)
	}
	var keyboard, input *PhoneNode
	walkNodes(model.Root, func(node *PhoneNode) {
		if keyboard == nil && node.AX.Type == keyboardAutomationType && node.Shown() {
			keyboard = node
		}
	})
	var over []Rect
	if keyboard != nil {
		over = append(over, keyboard.Visible)
		input = keyboard.window()
	}
	if model.System != nil {
		walkNodes(model.System, func(node *PhoneNode) {
			if node.Shown() && node.AX.AccessibilityElement && len(node.Children) == 0 && !node.inStatusBar() {
				over = append(over, node.Visible)
			}
		})
	}
	walkNodes(model.Root, func(node *PhoneNode) {
		if node.Shown() && (input == nil || !input.Contains(node)) {
			node.Covered = slices.ContainsFunc(over, func(rect Rect) bool { return rect.Contains(node.Point) })
		}
	})
	return model
}

// The keyboard has a window of its own, which also holds the candidate bar
// outside the keyboard (iPhone18,2, iOS 27.2 24B115).
func (n *PhoneNode) window() *PhoneNode {
	for node := n; node != nil; node = node.Parent {
		if node.AX.Type == windowAutomationType {
			return node
		}
	}
	return n
}

func (n *PhoneNode) inStatusBar() bool {
	for node := n; node != nil; node = node.Parent {
		if node.AX.Type == statusBarAutomationType {
			return true
		}
	}
	return false
}

func (m *PhoneModel) convert(space axSpace, node *accessibility.TreeNode, parent *PhoneNode, focused *accessibility.ElementRef) *PhoneNode {
	if node.Type == windowAutomationType && node.Frame != nil {
		space = space.window(node.Frame)
	}
	out := &PhoneNode{AX: node.Element, Inert: node.Inert, Web: node.Web, Parent: parent, Remote: space.remote(node.Element), model: m}
	m.nodes[node.Ref] = out
	if out.HasFrame() {
		out.Frame = space.rect(*node.Frame)
		out.Clip = space.rect(node.Clip)
		out.Visible = out.Frame.Intersect(out.Clip).Intersect(Rect{Width: space.geometry.Width, Height: space.geometry.Height})
		out.Point = out.Visible.Center()
		if activation := node.Activation; activation != nil {
			if point := space.point(*activation); out.Visible.Contains(point) {
				out.Point = point
			}
		}
	}
	out.Focused = focused != nil && *focused == node.Ref && node.TextEntry()
	for _, child := range node.Children {
		out.Children = append(out.Children, m.convert(space, child, out, focused))
	}
	return out
}

func (p *Phone) read(ctx context.Context, a *attachment) (*PhoneModel, error) {
	geometry, err := p.readGeometry(ctx, a)
	if err != nil {
		return nil, err
	}
	springboardPID := p.springboard.Load()
	if springboardPID == 0 {
		processes, err := apps.Processes(ctx, a.device)
		if err != nil {
			return nil, err
		}
		springboard := common.Find(processes, func(it apps.Process) bool { return strings.HasSuffix(it.Executable, "/SpringBoard.app/SpringBoard") })
		if springboard.PID == 0 {
			return nil, E.New("SpringBoard is not running")
		}
		springboardPID = springboard.PID
		p.springboard.Store(springboardPID)
	}
	started := time.Now()
	var screen *accessibility.Screen
	err = p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) (err error) {
		screen, err = client.ReadScreen(ctx, springboardPID)
		return
	})
	if errors.Is(err, accessibility.ErrNoApplication) {
		p.springboard.Store(0)
	}
	if err != nil {
		return nil, err
	}
	model := modelOf(geometry, screen)
	p.logger.Debug("read ", len(model.nodes), " nodes of ", model.BundleID, " in ", time.Since(started), ", rounds ", fmt.Sprint(screen.Rounds))
	return model, nil
}

func (p *Phone) Read(ctx context.Context) (*PhoneModel, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	return p.read(ctx, a)
}

func (p *Phone) ElementAt(ctx context.Context, at Point) (accessibility.Element, *PhoneNode, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return accessibility.Element{}, nil, err
	}
	defer cancel()
	geometry, err := p.readGeometry(ctx, a)
	if err != nil {
		return accessibility.Element{}, nil, err
	}
	if err = geometry.check(at); err != nil {
		return accessibility.Element{}, nil, err
	}
	hit, err := p.hitTest(ctx, a, geometry, at)
	if err != nil {
		return accessibility.Element{}, nil, err
	}
	model, err := p.read(ctx, a)
	if err != nil {
		return accessibility.Element{}, nil, err
	}
	return hit, model.Node(hit.Ref), nil
}

func (p *Phone) hitTest(ctx context.Context, a *attachment, geometry phoneGeometry, at Point) (accessibility.Element, error) {
	var hit accessibility.Element
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		found := batch.HitTest(geometry.digitizer(at))
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		if err := found.Err("hit-test the screen"); err != nil {
			return err
		}
		read := &accessibility.Batch{}
		attributes := read.Attributes(found.Value)
		if err := client.Run(ctx, read); err != nil {
			return err
		}
		hit = attributes.Value
		return attributes.Err("read the hit element")
	})
	return hit, err
}

type PhoneStatus struct {
	Name, Model, OSVersion, Build string
	Screen                        PhoneScreen
	Locked                        bool
	Display                       string
	BundleID                      string
	Language                      string
}

func (p *Phone) Status(ctx context.Context) (PhoneStatus, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return PhoneStatus{}, err
	}
	defer cancel()
	info := a.device.Info()
	status := PhoneStatus{Name: p.server.options.Name, Model: info.ProductType, OSVersion: info.OSVersion, Build: info.BuildVersion}
	geometry, err := p.readGeometry(ctx, a)
	if err != nil {
		return PhoneStatus{}, err
	}
	status.Screen = geometry.PhoneScreen
	if status.Locked, err = p.lockState.locked(ctx, a.device); err != nil {
		return PhoneStatus{}, E.Cause(err, "read the lock state")
	}
	if status.Display, err = p.backlight(ctx, a); err != nil {
		return PhoneStatus{}, err
	}
	if status.Language, err = a.device.Language(ctx); err != nil {
		return PhoneStatus{}, err
	}
	status.BundleID, err = p.frontmost(ctx, a)
	return status, err
}

func (p *Phone) frontmost(ctx context.Context, a *attachment) (string, error) {
	var bundleID string
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		front := batch.Frontmost()
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		if err := front.Err("read the frontmost application"); err != nil {
			return err
		}
		read := &accessibility.Batch{}
		bundle := read.BundleID(front.Value)
		if err := client.Run(ctx, read); err != nil {
			return err
		}
		bundleID = bundle.Value
		return bundle.Err("read the frontmost application's bundle ID")
	})
	return bundleID, err
}

func (p *Phone) backlight(ctx context.Context, a *attachment) (string, error) {
	if read := p.server.options.BacklightState; read != nil {
		switch read() {
		case 0:
			return "off", nil
		case 1:
			return "inactiveOn", nil
		case 2:
			return "activeOn", nil
		case 3:
			return "dimmed", nil
		}
	}
	state, err := a.display.BacklightState(ctx)
	if err != nil {
		return "", E.Cause(err, "read the backlight state")
	}
	return state, nil
}

func (p *Phone) Apps(ctx context.Context) ([]apps.App, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	return apps.List(ctx, a.device)
}

func (p *Phone) Clipboard(ctx context.Context) (string, bool, error) {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return "", false, err
	}
	defer cancel()
	snapshot, err := a.pasteboard.Read(ctx)
	if errors.Is(err, pasteboard.ErrRefused) {
		return "", false, E.New("the clipboard holds an item the device does not hand out, such as a copied password")
	}
	if err != nil {
		return "", false, err
	}
	text, ok := snapshot.Text()
	return text, ok, nil
}

func (p *Phone) SetClipboard(ctx context.Context, text *string) error {
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	written := make(chan error, 1)
	if text == nil {
		err = a.pasteboard.Clear(ctx, func(err error) { written <- err })
	} else {
		err = a.pasteboard.WriteText(ctx, *text, func(err error) { written <- err })
	}
	if err != nil {
		return err
	}
	select {
	case err = <-written:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Safari's tab bar reports its address after a U+200E (iPhone18,2, iOS 27.2
// 24B115); times put U+202F before AM and PM, and phone numbers U+00A0
// between groups (iPhone18,2, iOS 27.0.1 24A446).
func PlainText(text string) string {
	return strings.Map(plainRune, text)
}

func plainRune(r rune) rune {
	switch {
	case unicode.Is(unicode.Bidi_Control, r):
		return -1
	case r == '\u00a0', r == '\u2007', r == '\u2009', r == '\u202f':
		return ' '
	}
	return r
}
