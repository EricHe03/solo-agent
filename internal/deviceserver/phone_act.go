package deviceserver

import (
	"context"
	"errors"
	"maps"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/coredevice/apps"
	"github.com/swipt-automation/swipt/internal/coredevice/hid"
)

// A test app came to the front 122 to 138 ms after a warm launch request and
// 662 to 1,042 ms after a cold one, and Clock 1.71 s after a cold one
// (iPhone18,2, iOS 27.2 24B115).
const launchLimit = 3500 * time.Millisecond

// A text field takes the focus as the tap's touch-up is handled, and the
// device reports the change within 150 ms (iPad17,1, iPadOS 27.2 24B115).
const focusLimit = 500 * time.Millisecond

const stillLimit = 3 * time.Second

// While Control Center opened, a read of the screen took up to 4.57 s
// (iPhone18,2, iOS 27.2 24B115).
const settleLimit = 7 * time.Second

type PhoneResult struct {
	Target   *PhoneNode
	Warnings []string
}

type action struct {
	unlocked bool
	input    func(ctx context.Context, a *attachment, geometry phoneGeometry, result *PhoneResult) error
	check    func(ctx context.Context, a *attachment, result *PhoneResult) error
}

func (p *Phone) act(ctx context.Context, do action) (*PhoneResult, error) {
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer cancel()
	result := &PhoneResult{}
	err = func() error {
		p.access.Lock()
		defer p.access.Unlock()
		if do.unlocked {
			if err := p.requireScreen(ctx, a); err != nil {
				return err
			}
		}
		defer p.forgetFront()
		geometry, err := p.readGeometry(ctx, a)
		if err != nil {
			return err
		}
		return do.input(ctx, a, geometry, result)
	}()
	if err != nil {
		return nil, err
	}
	if do.check != nil {
		if err = do.check(ctx, a, result); err != nil {
			return nil, E.Cause(err, "check the result")
		}
	}
	return result, nil
}

func (p *Phone) requireScreen(ctx context.Context, a *attachment) error {
	locked, err := p.lockState.locked(ctx, a.device)
	if err != nil {
		return E.Cause(err, "read the lock state")
	}
	if locked {
		return E.New("the phone is locked; unlock it with phone.unlock() first")
	}
	display, err := p.backlight(ctx, a)
	if err != nil {
		return err
	}
	if display == "off" {
		return E.New("the screen is off; wake it with phone.pressHome()")
	}
	return nil
}

func (p *Phone) verify(ctx context.Context, a *attachment, target *PhoneNode) (accessibility.Element, error) {
	var mapped *accessibility.Result[bool]
	var attributes *accessibility.Result[accessibility.Element]
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		mapped = batch.Mapped(target.AX)
		attributes = batch.Attributes(target.AX)
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		return mapped.Err("check the element")
	})
	if err != nil {
		return accessibility.Element{}, err
	}
	if !mapped.Value {
		return accessibility.Element{}, E.New(describeElement(target.AX), " is gone; find it again in a new phone.screen()")
	}
	if err := attributes.Err("read the element"); err != nil {
		return accessibility.Element{}, err
	}
	if !attributes.Value.Enabled {
		return accessibility.Element{}, E.New(describeElement(target.AX), " is disabled")
	}
	return attributes.Value, nil
}

func (p *Phone) locate(ctx context.Context, a *attachment, geometry phoneGeometry, target *PhoneNode, result *PhoneResult) (Point, error) {
	if !target.HasFrame() {
		return Point{}, E.New(describeElement(target.AX), " has no position on the screen; act on it with phone.perform() instead")
	}
	unmoved, err := p.unmoved(ctx, a, geometry, target)
	if err != nil {
		return Point{}, err
	}
	if unmoved {
		result.Target = target
		return target.Point, nil
	}
	if _, err := p.verify(ctx, a, target); err != nil {
		return Point{}, err
	}
	frame, err := p.still(ctx, a, target)
	if err != nil {
		return Point{}, err
	}
	current := target
	if !equalFrame(frame, target.AX.Frame) || !target.Shown() || target.Covered {
		model, err := p.read(ctx, a)
		if err != nil {
			return Point{}, err
		}
		if current = model.Node(target.AX.Ref); current == nil || !current.HasFrame() {
			return Point{}, E.New(describeElement(target.AX), " is no longer on the screen; ", model.BundleID, " is in front")
		}
		if !current.Shown() || current.Covered {
			if current, err = p.reveal(ctx, a, current, result); err != nil {
				return Point{}, err
			}
		}
	}
	current, at, err := p.reach(ctx, a, geometry, current)
	if err != nil {
		return Point{}, err
	}
	if at != current.Point {
		result.Warnings = append(result.Warnings, describeElement(current.AX)+" is covered at its point, so it was tapped at "+pointText(at))
	}
	result.Target = current
	return at, nil
}

func (p *Phone) unmoved(ctx context.Context, a *attachment, geometry phoneGeometry, target *PhoneNode) (bool, error) {
	if !target.Shown() || target.Covered {
		return false, nil
	}
	var unmoved bool
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		mapped := batch.Mapped(target.AX)
		attributes := batch.Attributes(target.AX)
		hit := batch.HitTest(geometry.digitizer(target.Point))
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		if mapped.Code != 0 || !mapped.Value || attributes.Code != 0 || !attributes.Value.Enabled ||
			!equalFrame(attributes.Value.Frame, target.AX.Frame) || hit.Code != 0 {
			return nil
		}
		node := target.model.Node(hit.Value.Ref)
		unmoved = hit.Value.Ref == target.AX.Ref || node != nil && target.Contains(node)
		return nil
	})
	return unmoved, err
}

func equalFrame(first, second *accessibility.LayoutFrame) bool {
	return first == nil && second == nil || first != nil && second != nil && *first == *second
}

func (p *Phone) reveal(ctx context.Context, a *attachment, target *PhoneNode, result *PhoneResult) (*PhoneNode, error) {
	var performed bool
	err := p.withAccessibility(ctx, a, false, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		perform := batch.Perform(target.AX, accessibility.ActionScrollToVisible)
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		performed = perform.Value
		return perform.Err("scroll the element into view")
	})
	if err != nil {
		return nil, err
	}
	state := "off screen"
	if target.Covered {
		state = "covered by the keyboard or a banner"
	}
	if !performed {
		return nil, E.New(describeElement(target.AX), " is ", state, ", and its scroll view refused to scroll it into view")
	}
	if _, err = p.still(ctx, a, target); err != nil {
		return nil, err
	}
	model, err := p.read(ctx, a)
	if err != nil {
		return nil, err
	}
	current := model.Node(target.AX.Ref)
	if current == nil {
		return nil, E.New(describeElement(target.AX), " is gone after scrolling it into view; find it again in a new phone.screen()")
	}
	if !current.Shown() || current.Covered {
		return nil, E.New(describeElement(current.AX), " stayed ", state, " after scrolling it into view")
	}
	result.Warnings = append(result.Warnings, "scrolled "+describeElement(current.AX)+" into view first")
	return current, nil
}

// UIKit answers a page scroll action with the content offset still animating
// (24B5110a UIKit.axbundle 0x189ff2200, 0x189ff2ea4), and the translator folds
// the page-scrolled notification into a later tree push instead of forwarding
// it (24B5110a AccessibilityPlatformTranslation 0x253fe623c); a tap on a list
// still scrolling only stops it, while web content can answer its old frame
// twice (iPhone18,2, iOS 27.2 24B115).
func (p *Phone) still(ctx context.Context, a *attachment, target *PhoneNode) (*accessibility.LayoutFrame, error) {
	deadline := time.Now().Add(stillLimit)
	var last *accessibility.LayoutFrame
	for read := 0; ; read++ {
		element, err := p.attributes(ctx, a, target)
		if err != nil {
			return nil, err
		}
		if read > 0 && equalFrame(element.Frame, last) {
			return element.Frame, nil
		}
		if time.Now().After(deadline) {
			return nil, E.New(describeElement(target.AX), " kept moving for ", stillLimit)
		}
		last = element.Frame
	}
}

func (p *Phone) reach(ctx context.Context, a *attachment, geometry phoneGeometry, target *PhoneNode) (*PhoneNode, Point, error) {
	at := target.Point
	refreshed := false
	for attempt := 0; ; attempt++ {
		hit, err := p.hitTest(ctx, a, geometry, at)
		if err != nil {
			return nil, Point{}, err
		}
		node := target.model.Node(hit.Ref)
		if node == nil && !refreshed {
			refreshed = true
			model, err := p.read(ctx, a)
			if err != nil {
				return nil, Point{}, err
			}
			current := model.Node(target.AX.Ref)
			if current == nil || !current.Shown() {
				return nil, Point{}, E.New(describeElement(target.AX), " is no longer on the screen; ", model.BundleID, " is in front")
			}
			target, at, attempt = current, current.Point, -1
			continue
		}
		if hit.Ref == target.AX.Ref || node != nil && (target.Contains(node) || hit.AccessibilityElement && node.Contains(target)) || node == nil && within(target.AX.Frame, hit.Frame) {
			return target, at, nil
		}
		if attempt == 0 && node != nil && node.Shown() {
			if piece := common.MaxBy(target.Visible.subtract(node.Visible), Rect.area); piece.area() > 0 {
				at = piece.Center()
				continue
			}
		}
		if target.Inert {
			return nil, Point{}, E.New(describeElement(target.AX), " is behind a modal view, as a sheet or an alert: a tap at ", pointText(at), " would reach ", describeElement(hit))
		}
		return nil, Point{}, E.New("a tap at ", pointText(at), " would reach ", describeElement(hit), ", not ", describeElement(target.AX), "; press it with phone.perform() instead, or pass the point to phone.tap() to tap there anyway")
	}
}

// The keyboard's candidate bar lists each candidate as an element the
// snapshot shows, while the hit test answers the label inside it, which the
// snapshot does not (iPhone18,2, iOS 27.2 24B115).
func within(outer, inner *accessibility.LayoutFrame) bool {
	return outer != nil && inner != nil && inner.X >= outer.X-1 && inner.Y >= outer.Y-1 &&
		inner.X+inner.Width <= outer.X+outer.Width+1 && inner.Y+inner.Height <= outer.Y+outer.Height+1
}

func pointText(at Point) string {
	return "[" + strconv.FormatFloat(math.Round(at.X*10)/10, 'f', -1, 64) + ", " + strconv.FormatFloat(math.Round(at.Y*10)/10, 'f', -1, 64) + "]"
}

func describeElement(element accessibility.Element) string {
	switch {
	case element.Label != "":
		return "the element " + strconv.Quote(PlainText(element.Label))
	case element.Identifier != "":
		return "the element with the identifier " + strconv.Quote(element.Identifier)
	case element.Value != "":
		return "the element valued " + strconv.Quote(PlainText(element.Value))
	case element.Class != "":
		return "an unlabeled " + element.Class
	}
	return "an unlabeled element"
}

func (p *Phone) TapElement(ctx context.Context, target *PhoneNode, count int, hold time.Duration) (*PhoneResult, error) {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, a *attachment, geometry phoneGeometry, result *PhoneResult) error {
		at, err := p.locate(ctx, a, geometry, target, result)
		if err != nil {
			return err
		}
		return p.tap(ctx, a, geometry, at, count, hold)
	}})
}

func (p *Phone) TapPoint(ctx context.Context, at Point, count int, hold time.Duration) (*PhoneResult, error) {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, a *attachment, geometry phoneGeometry, _ *PhoneResult) error {
		if err := geometry.check(at); err != nil {
			return err
		}
		return p.tap(ctx, a, geometry, at, count, hold)
	}})
}

func (p *Phone) Touch(ctx context.Context, fingers [][]TouchSample) (*PhoneResult, error) {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, a *attachment, geometry phoneGeometry, _ *PhoneResult) error {
		if err := checkFingers(geometry, fingers); err != nil {
			return err
		}
		return p.play(ctx, a, geometry, fingers)
	}})
}

func (p *Phone) Pinch(ctx context.Context, center Point, scale float64, duration time.Duration) (*PhoneResult, error) {
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, a *attachment, geometry phoneGeometry, _ *PhoneResult) error {
		fingers, err := pinchPath(geometry, center, scale, duration)
		if err != nil {
			return err
		}
		return p.play(ctx, a, geometry, fingers)
	}})
}

var phoneActions = map[string]uint64{
	"press": accessibility.ActionPress, "increment": accessibility.ActionIncrement, "decrement": accessibility.ActionDecrement,
	"escape": accessibility.ActionEscape, "menu": accessibility.ActionShowContextMenu,
	"scrollUp": accessibility.ActionScrollUpByPage, "scrollDown": accessibility.ActionScrollDownByPage,
	"scrollLeft": accessibility.ActionScrollLeftByPage, "scrollRight": accessibility.ActionScrollRightByPage,
	"scrollToVisible": accessibility.ActionScrollToVisible,
}

func (p *Phone) Perform(ctx context.Context, target *PhoneNode, name string) (*PhoneResult, error) {
	number, standard := phoneActions[name]
	custom := common.Find(target.AX.Actions, func(candidate accessibility.CustomAction) bool { return candidate.Name == name })
	if !standard && custom.Identifier == "" {
		names := append(slices.Sorted(maps.Keys(phoneActions)), common.Map(target.AX.Actions, func(it accessibility.CustomAction) string { return it.Name })...)
		return nil, E.New(describeElement(target.AX), " has no action ", strconv.Quote(name), "; its actions are ", strings.Join(names, ", "))
	}
	return p.act(ctx, action{input: func(ctx context.Context, a *attachment, _ phoneGeometry, result *PhoneResult) error {
		if !target.AX.Enabled {
			if _, err := p.verify(ctx, a, target); err != nil {
				return err
			}
		}
		result.Target = target
		var performed bool
		err := p.withAccessibility(ctx, a, false, func(client *accessibility.RemoteClient) error {
			batch := &accessibility.Batch{}
			mapped := batch.Mapped(target.AX)
			var perform *accessibility.Result[bool]
			if standard {
				perform = batch.Perform(target.AX, number)
			} else {
				perform = batch.PerformCustom(target.AX, custom)
			}
			if err := client.Run(ctx, batch); err != nil {
				return err
			}
			if err := mapped.Err("check the element"); err != nil {
				return err
			}
			if !mapped.Value {
				return E.New(describeElement(target.AX), " is gone; find it again in a new phone.screen()")
			}
			performed = perform.Value
			return perform.Err("perform " + strconv.Quote(name))
		})
		if err == nil && !performed {
			err = E.New(describeElement(target.AX), " refused to perform ", strconv.Quote(name))
		}
		return err
	}})
}

func (p *Phone) Supports(ctx context.Context, target *PhoneNode, name string) (bool, error) {
	number, standard := phoneActions[name]
	if !standard {
		return false, E.New("unknown standard action ", strconv.Quote(name))
	}
	p.access.Lock()
	defer p.access.Unlock()
	a, ctx, cancel, err := p.begin(ctx)
	if err != nil {
		return false, err
	}
	defer cancel()
	var supported bool
	err = p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		result := batch.SupportedActions(target.AX, []uint64{number})
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		supported = slices.Contains(result.Value, number)
		return result.Err("read the supported actions")
	})
	return supported, err
}

// A backspace from the keyboard changed Claude's chat input 177 to 518 ms after
// it was sent (iPhone18,2, iOS 27.2 24B115).
const keyLimit = 2 * time.Second

func (p *Phone) SetText(ctx context.Context, target *PhoneNode, text string) (*PhoneResult, error) {
	var nudge bool
	return p.act(ctx, action{
		input: func(ctx context.Context, a *attachment, geometry phoneGeometry, result *PhoneResult) error {
			if err := p.focus(ctx, a, geometry, target, result); err != nil {
				return err
			}
			// UIKit sets a text view's value with setText: and
			// keyboardInputChanged: alone, which Claude's chat input did not
			// take as an edit, while a text field's setter sends
			// fieldEditorDidChange: and a focused web entry inserts the text
			// through its editor (24B5110a UIKit.axbundle 0x18a052c34,
			// 0x18a047f50; 24B5110a UIKitCore 0x185cffcc4; WebKit f98a24d3,
			// Source/WebCore/accessibility/AccessibilityRenderObject.cpp:1886;
			// iPhone18,2, iOS 27.2 24B115). Deleting a trailing space with
			// the keyboard made it one.
			nudge = result.Target.AX.TextView() && !result.Target.Web
			value := text
			if nudge {
				value += " "
			}
			err := p.withAccessibility(ctx, a, false, func(client *accessibility.RemoteClient) error {
				batch := &accessibility.Batch{}
				set := batch.SetValue(result.Target.AX, value)
				if err := client.Run(ctx, batch); err != nil {
					return err
				}
				return set.Err("set the text")
			})
			if err != nil || !nudge {
				return err
			}
			return p.pressKeys(ctx, a, []uint8{usageBackspace})
		},
		check: func(ctx context.Context, a *attachment, result *PhoneResult) error {
			deadline := time.Now().Add(keyLimit)
			for {
				err := p.checkText(ctx, a, result.Target, text)
				if err == nil || !nudge || ctx.Err() != nil || time.Now().After(deadline) {
					return err
				}
			}
		},
	})
}

// Tapping a text field can bring another entry in its place, as Safari's
// address bar gives way to its editing field (iPhone18,2, iOS 27.2 24B115).
func (p *Phone) focus(ctx context.Context, a *attachment, geometry phoneGeometry, target *PhoneNode, result *PhoneResult) error {
	result.Target = target
	if !target.AX.TextInput() {
		return E.New(describeElement(target.AX), " is not a text entry")
	}
	app := target.model.Root.AX
	before, err := p.focusedElement(ctx, a, app)
	if err != nil {
		return err
	}
	if before != nil && *before == target.AX.Ref {
		return nil
	}
	at, err := p.locate(ctx, a, geometry, target, result)
	if err != nil {
		return err
	}
	if err = p.tap(ctx, a, geometry, at, 1, 0); err != nil {
		return err
	}
	deadline := time.Now().Add(focusLimit)
	for {
		focused, err := p.focusedElement(ctx, a, app)
		if err != nil {
			return err
		}
		if focused != nil && (before == nil || *focused != *before) {
			if *focused == target.AX.Ref {
				return nil
			}
			model, err := p.read(ctx, a)
			if err != nil {
				return err
			}
			node := model.Node(*focused)
			if node == nil {
				return E.New("tapping ", describeElement(target.AX), " focused an element the screen does not list")
			}
			result.Target = node
			result.Warnings = append(result.Warnings, "tapping "+describeElement(target.AX)+" focused "+describeElement(node.AX)+", which took the text")
			return nil
		}
		if time.Now().After(deadline) {
			if before != nil {
				held := "another element"
				if node := target.model.Node(*before); node != nil {
					held = describeElement(node.AX)
				}
				return E.New("tapping ", describeElement(target.AX), " left the keyboard focus on ", held)
			}
			return E.New("tapping ", describeElement(target.AX), " did not focus a text entry")
		}
	}
}

func (p *Phone) focusedElement(ctx context.Context, a *attachment, app accessibility.Element) (*accessibility.ElementRef, error) {
	var ref *accessibility.ElementRef
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		focused := batch.Focused(app)
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		if focused.Code == 0 {
			found := focused.Value.Ref
			ref = &found
		}
		return nil
	})
	return ref, err
}

func (p *Phone) attributes(ctx context.Context, a *attachment, target *PhoneNode) (accessibility.Element, error) {
	var attributes *accessibility.Result[accessibility.Element]
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		attributes = batch.Attributes(target.AX)
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		return attributes.Err("read the element")
	})
	if err != nil {
		return accessibility.Element{}, err
	}
	return attributes.Value, nil
}

func (p *Phone) checkText(ctx context.Context, a *attachment, target *PhoneNode, text string) error {
	element, err := p.attributes(ctx, a, target)
	if err == nil {
		err = element.TextErr()
	}
	if err != nil {
		return err
	}
	value, placeholder, expected := PlainText(element.Value), PlainText(element.Placeholder), PlainText(text)
	switch {
	// UIKit and WebKit answer a secure entry's value as one • per UTF-16 code
	// unit of its text (24B5110a UIKit.axbundle -[UIView
	// _accessibilitySecureTextForString:] 0x18a046274; WebKit f98a24d3,
	// Source/WebCore/accessibility/ios/WebAccessibilityObjectWrapperIOS.mm:1690,
	// Source/WebCore/accessibility/ios/AccessibilityObjectIOS.mm:107).
	case target.AX.Secure():
		units := len(utf16.Encode([]rune(text)))
		if placeholder != "" && value == placeholder {
			if expected == "" {
				return nil
			}
			return E.New(describeElement(target.AX), " shows its placeholder instead of ", units, " UTF-16 code units")
		}
		if masked := len(utf16.Encode([]rune(value))); masked != units {
			return E.New(describeElement(target.AX), " holds ", masked, " UTF-16 code units after setting ", units)
		}
		return nil
	case placeholder == "" || value != placeholder:
		if value == expected {
			return nil
		}
		return E.New(describeElement(target.AX), " holds ", strconv.Quote(value), " instead of ", strconv.Quote(text))
	case expected != "" && expected != placeholder:
		return E.New(describeElement(target.AX), " shows its placeholder instead of ", strconv.Quote(text))
	}
	empty, err := p.empty(ctx, a, target)
	if err != nil {
		return err
	}
	if empty != (expected == "") {
		return E.New(describeElement(target.AX), " holds ", strconv.Quote(value), " instead of ", strconv.Quote(text))
	}
	return nil
}

const nativeHandwriting = 2601

// UIKit answers native attribute 2601 with handwriting attributes only for an
// element _accessibilitySupportsHandwriting accepts, and their
// AXVoiceOverHandwritingAttributeCanDeleteCharacter is hasText for a
// UIKeyInput and YES for anything else (24B5110a UIAccessibility 0x1bbde7d10,
// 0x1bbdf8e08, 0x1bbdf8e90, 0x1bbdf9248); WebCore reports its placeholder as
// the value of an empty input (24A446 WebCore.axbundle 0x242ab8a54).
func (p *Phone) empty(ctx context.Context, a *attachment, target *PhoneNode) (bool, error) {
	if target.Web {
		return false, E.New(describeElement(target.AX), " shows its placeholder, and the server has no way to tell an empty web input from one holding that text")
	}
	var handwriting any
	err := p.withAccessibility(ctx, a, true, func(client *accessibility.RemoteClient) error {
		batch := &accessibility.Batch{}
		native := batch.Native(target.AX, nativeHandwriting)
		if err := client.Run(ctx, batch); err != nil {
			return err
		}
		handwriting = native.Value
		return native.Err("read the handwriting attributes")
	})
	if err != nil {
		return false, err
	}
	fields, _ := handwriting.(map[string]any)
	deletable, known := fields["AXVoiceOverHandwritingAttributeCanDeleteCharacter"].(bool)
	if !known {
		return false, E.New(describeElement(target.AX), " shows its placeholder, and answers no handwriting attributes that would tell whether it is empty or holds that text")
	}
	return !deletable, nil
}

func (p *Phone) Key(ctx context.Context, combo string) (*PhoneResult, error) {
	usages, err := parseKeyCombo(combo)
	if err != nil {
		return nil, err
	}
	return p.act(ctx, action{unlocked: true, input: func(ctx context.Context, a *attachment, _ phoneGeometry, _ *PhoneResult) error {
		return p.pressKeys(ctx, a, usages)
	}})
}

var phoneButtons = map[string][]hid.Button{
	"home": {hid.ButtonHome}, "appSwitcher": {hid.ButtonHome, hid.ButtonHome},
	"power": {{UsagePage: hid.ButtonLock.UsagePage, Usage: hid.ButtonLock.Usage}}, "volumeUp": {hid.ButtonVolumeUp}, "volumeDown": {hid.ButtonVolumeDown},
}

const springboardBundleID = "com.apple.springboard"

func (p *Phone) Button(ctx context.Context, name string) (*PhoneResult, error) {
	buttons, known := phoneButtons[name]
	if !known {
		return nil, E.New("unknown button ", strconv.Quote(name))
	}
	var check func(ctx context.Context, a *attachment, result *PhoneResult) error
	if name == "home" || name == "appSwitcher" {
		check = func(ctx context.Context, a *attachment, result *PhoneResult) error {
			if _, err := p.waitFront(ctx, a, springboardBundleID, time.Now().Add(launchLimit)); err != nil {
				return err
			}
			var front string
			_, err := p.settle(ctx, a, time.Now().Add(settleLimit), func(model *PhoneModel) (string, error) {
				front = model.BundleID
				return signature(model.Root, model.System), nil
			})
			if err == nil && front != springboardBundleID {
				result.Warnings = append(result.Warnings, front+" is in front")
			}
			return err
		}
	}
	return p.act(ctx, action{
		input: func(ctx context.Context, a *attachment, _ phoneGeometry, _ *PhoneResult) error {
			return p.withInput(a, func(input *hid.Client) error {
				for index, button := range buttons {
					if index > 0 {
						if err := sleep(ctx, homeGap); err != nil {
							return err
						}
					}
					if err := input.PressButton(ctx, button); err != nil {
						return err
					}
				}
				return nil
			})
		},
		check: check,
	})
}

func (p *Phone) waitFront(ctx context.Context, a *attachment, bundleID string, deadline time.Time) (string, error) {
	for {
		front, err := p.frontmost(ctx, a)
		if err != nil || front == bundleID || time.Now().After(deadline) {
			return front, err
		}
	}
}

func (p *Phone) settle(ctx context.Context, a *attachment, deadline time.Time, sign func(model *PhoneModel) (string, error)) (bool, error) {
	var last string
	for {
		model, err := p.read(ctx, a)
		if errors.Is(err, accessibility.ErrNoAnswer) && time.Now().Before(deadline) {
			continue
		}
		if err != nil {
			return false, err
		}
		current, err := sign(model)
		if err != nil {
			return false, err
		}
		if current == last {
			return true, nil
		}
		if time.Now().After(deadline) {
			return false, nil
		}
		last = current
	}
}

func (p *Phone) Launch(ctx context.Context, bundleID, url string, restart, animated bool) (*PhoneResult, error) {
	var started time.Time
	return p.act(ctx, action{
		unlocked: true,
		input: func(ctx context.Context, a *attachment, _ phoneGeometry, _ *PhoneResult) error {
			started = time.Now()
			launchContext, cancel := context.WithDeadline(ctx, started.Add(launchLimit))
			defer cancel()
			err := apps.Launch(launchContext, a.device, bundleID, url, restart, animated)
			if err == nil {
				return nil
			}
			list, listErr := apps.List(ctx, a.device)
			if listErr == nil && !slices.ContainsFunc(list, func(app apps.App) bool { return app.BundleID == bundleID }) {
				return E.Cause(err, "no app with the bundle ID ", strconv.Quote(bundleID), " is listed")
			}
			return E.Append(err, listErr, func(err error) error { return E.Cause(err, "list the apps") })
		},
		check: func(ctx context.Context, a *attachment, result *PhoneResult) error {
			front, err := p.waitFront(ctx, a, bundleID, started.Add(launchLimit))
			if err != nil {
				return err
			}
			if front != bundleID {
				return E.New(bundleID, " launched, but ", front, " is still in front after ", launchLimit)
			}
			settled, err := p.settle(ctx, a, started.Add(launchLimit), func(model *PhoneModel) (string, error) {
				if model.BundleID != bundleID {
					return "", E.New(bundleID, " came to the front, and then ", model.BundleID, " did")
				}
				return signature(model.Root, model.System), nil
			})
			if err == nil && !settled {
				result.Warnings = append(result.Warnings, bundleID+" was still changing its screen "+launchLimit.String()+" after the launch")
			}
			return err
		},
	})
}

func (p *Phone) Unlock(ctx context.Context) (*PhoneResult, error) {
	settings := p.server.settings.Load()
	if settings.AutoUnlockPasscode == "" {
		return nil, E.New("no unlock passcode is configured on this server")
	}
	return p.act(ctx, action{input: func(ctx context.Context, a *attachment, _ phoneGeometry, _ *PhoneResult) error {
		buttons := &p.server.buttons.access
		buttons.Lock()
		defer buttons.Unlock()
		if err := p.closeInput(); err != nil {
			return err
		}
		input := hid.New(a.owner, a.device, p.logger, hid.HardwareKeyboard)
		target := &deviceUnlockTarget{
			server: p.server, settings: settings, device: a, input: input, keys: newKeyboard(),
			lockState: &p.lockState, logger: p.logger,
		}
		_, err := target.unlock(ctx)
		if target.accessibility != nil {
			err = E.Append(err, target.accessibility.Close(), func(err error) error {
				return E.Cause(err, "stop unlock accessibility")
			})
		}
		err = E.Append(err, input.Close(), func(err error) error {
			return E.Cause(err, "close the unlock input")
		})
		if err != nil {
			return E.Cause(p.reopenStalled(ctx, a, nil, true, err), "unlock")
		}
		return nil
	}})
}
