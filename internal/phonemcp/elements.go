//go:build darwin && cgo

package phonemcp

import (
	"math"
	"slices"
	"strings"
	"unicode"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/coredevice/accessibility"
	"github.com/swipt-automation/swipt/internal/deviceserver"
)

var roles = [...]string{
	"element", "other", "application", "group", "window", "sheet", "drawer", "alert", "dialog",
	"button", "radioButton", "radioGroup", "checkBox", "disclosureTriangle", "popUpButton",
	"comboBox", "menuButton", "toolbarButton", "popover", "keyboard", "key",
	"navigationBar", "tabBar", "tabGroup", "toolbar", "statusBar", "table", "tableRow",
	"tableColumn", "outline", "outlineRow", "browser", "collectionView", "slider",
	"pageIndicator", "progressIndicator", "activityIndicator", "segmentedControl", "picker",
	"pickerWheel", "switch", "toggle", "link", "image", "icon", "searchField",
	"scrollView", "scrollBar", "text", "textField", "secureTextField", "datePicker",
	"textView", "menu", "menuItem", "menuBar", "menuBarItem", "map", "webView",
	"incrementArrow", "decrementArrow", "timeline", "ratingIndicator", "valueIndicator",
	"splitGroup", "splitter", "relevanceIndicator", "colorWell", "helpTag", "matte",
	"dockItem", "ruler", "rulerMarker", "grid", "levelIndicator", "cell", "layoutArea",
	"layoutItem", "handle", "stepper", "tab", "touchBar", "statusItem",
}

// AXRuntime trait bits (24A446 AXRuntime _kAX*Trait).
var traits = [...]string{
	0: "button", 1: "link", 2: "image", 4: "playsSound", 5: "keyboardKey", 6: "staticText", 7: "summaryElement",
	9: "updatesFrequently", 10: "searchField", 11: "startsMediaSession", 12: "adjustable", 13: "allowsDirectInteraction",
	14: "causesPageTurn", 15: "tabBar", 16: "header", 17: "webContent", 18: "textEntry",
}

const (
	traitRadioButton = 1 << 20
	traitTabButton   = 1 << 28
	traitPopUpButton = 1 << 40
	traitToggle      = 1 << 53
)

var traitRoles = []struct{ trait, role string }{
	{"searchField", "searchField"},
	{"textEntry", "textField"},
	{"keyboardKey", "key"},
	{"adjustable", "slider"},
	{"link", "link"},
	{"button", "button"},
	{"image", "image"},
	{"tabBar", "tabBar"},
	{"staticText", "text"},
}

const (
	typeOther    = 1
	typeButton   = 9
	typeKeyboard = 19
)

// XCTest converts an automation type to XCUIElementType with this table (Xcode
// 27.1 27A9275 XCTAutomationSupport _XCTElementTypeFromAXAutomationType
// 0x1e444, 0x46e28).
func elementType(automation uint64) uint64 {
	switch {
	case automation < 8:
		return [...]uint64{1, 2, 4, 5, 6, 3, 7, 8}[automation]
	case automation == 8:
		return 83
	case automation == 83:
		return typeOther
	case automation >= 84 && automation <= 88:
		return typeButton
	case automation > 88:
		return 0
	}
	return automation
}

var structuralRoles = []string{
	"application", "window", "alert", "sheet", "dialog", "popover", "navigationBar", "tabBar", "toolbar",
	"statusBar", "table", "collectionView", "outline", "webView", "keyboard", "menu", "picker",
	"segmentedControl", "tabGroup", "radioGroup",
}

var scrollingRoles = []string{"scrollView", "table", "collectionView", "outline", "webView"}

var (
	contentRoles = []string{"text", "heading", "image"}
	genericRoles = []string{"other", "element", "group"}
)

type element struct {
	Ref         int         `json:"ref"`
	Role        string      `json:"role"`
	Class       string      `json:"class,omitempty"`
	Traits      []string    `json:"traits,omitempty"`
	Label       string      `json:"label,omitempty"`
	Value       string      `json:"-"`
	ShownValue  *string     `json:"value,omitempty"`
	Identifier  string      `json:"identifier,omitempty"`
	Placeholder string      `json:"placeholder,omitempty"`
	Hint        string      `json:"hint,omitempty"`
	URL         string      `json:"url,omitempty"`
	Frame       *[4]float64 `json:"frame,omitempty"`
	Point       *[2]float64 `json:"point,omitempty"`
	OffScreen   bool        `json:"offScreen,omitempty"`
	Partial     bool        `json:"partial,omitempty"`
	Inert       bool        `json:"inert,omitempty"`
	Remote      bool        `json:"remote,omitempty"`
	Disabled    bool        `json:"disabled,omitempty"`
	Focused     bool        `json:"focused,omitempty"`
	Selected    bool        `json:"selected,omitempty"`
	Expanded    *bool       `json:"expanded,omitempty"`
	Secure      bool        `json:"secure,omitempty"`
	Selection   *[2]uint64  `json:"selection,omitempty"`
	Actions     []string    `json:"actions,omitempty"`
	Children    []*element  `json:"children,omitempty"`

	node *deviceserver.PhoneNode
}

type screen struct {
	App    string   `json:"app"`
	Root   *element `json:"root"`
	System *element `json:"system,omitempty"`
}

const keptReads = 16

type elementTable struct {
	refs   map[accessibility.ElementRef]int
	nodes  map[int]*deviceserver.PhoneNode
	listed map[int]int
	reads  int
	next   int
}

func newElementTable() *elementTable {
	return &elementTable{refs: make(map[accessibility.ElementRef]int), nodes: make(map[int]*deviceserver.PhoneNode), listed: make(map[int]int)}
}

func (t *elementTable) screen(model *deviceserver.PhoneModel, unshaped bool) screen {
	t.reads++
	defer t.forget()
	shapeRoot := func(root *deviceserver.PhoneNode, system bool) *element {
		if unshaped {
			return raw(root, 0)
		}
		return shape(root, 0, system)[0]
	}
	var number func(item *element)
	number = func(item *element) {
		item.Ref = t.remember(item.node)
		for _, child := range item.Children {
			number(child)
		}
	}
	out := screen{App: model.BundleID, Root: shapeRoot(model.Root, false)}
	if !unshaped {
		tidy(out.Root, nil)
	}
	number(out.Root)
	if model.System != nil {
		if system := shapeRoot(model.System, true); len(system.Children) > 0 {
			out.System = system
			number(system)
		}
	}
	return out
}

// The parts of an element report its custom actions as their own, as those of
// a Home Screen icon, of the Dynamic Island and of Safari's address bar do
// (iPhone18,2, iOS 27.2 24B115).
func tidy(item *element, inherited []string) {
	own := item.Actions
	if len(own) > 0 && common.All(own, func(action string) bool { return slices.Contains(inherited, action) }) {
		item.Actions = nil
	}
	if len(own) > 0 {
		inherited = own
	}
	if len(item.Children) > 0 && !item.node.AX.AccessibilityElement && !isControl(item.Role) {
		item.Partial = false
	}
	for _, child := range item.Children {
		tidy(child, inherited)
	}
}

func (t *elementTable) remember(node *deviceserver.PhoneNode) int {
	ref, found := t.refs[node.AX.Ref]
	if !found {
		t.next++
		ref = t.next
		t.refs[node.AX.Ref] = ref
	}
	t.nodes[ref] = node
	t.listed[ref] = t.reads
	return ref
}

func (t *elementTable) forget() {
	for ref, read := range t.listed {
		if read > t.reads-keptReads {
			continue
		}
		delete(t.refs, t.nodes[ref].AX.Ref)
		delete(t.nodes, ref)
		delete(t.listed, ref)
	}
}

func (t *elementTable) describe(node *deviceserver.PhoneNode) *element {
	out := describe(node, -1)
	out.Ref = t.remember(node)
	return out
}

func (t *elementTable) node(ref int) (*deviceserver.PhoneNode, error) {
	found, ok := t.nodes[ref]
	switch {
	case ok:
		return found, nil
	case ref > 0 && ref <= t.next:
		return nil, E.New("the element with ref ", ref, " came from an earlier read of the screen; find it again in a new phone.screen()")
	}
	return nil, E.New("no element was listed with ref ", ref)
}

func (t *elementTable) act(name string) func(*deviceserver.PhoneResult, error) (any, error) {
	return func(result *deviceserver.PhoneResult, err error) (any, error) {
		if err != nil {
			return nil, err
		}
		out := actionResult{Action: name, Warnings: result.Warnings}
		if result.Target != nil {
			out.Target = t.describe(result.Target)
		}
		return out, nil
	}
}

func describe(node *deviceserver.PhoneNode, depth int) *element {
	ax := node.AX
	out := &element{
		Label: ax.Label, Value: ax.Value, Identifier: ax.Identifier, Placeholder: ax.Placeholder, Hint: ax.Help, URL: ax.URL,
		Remote: node.Remote, Inert: node.Inert, Disabled: !ax.Enabled, Focused: node.Focused, Selected: ax.Selected,
		Expanded: ax.Expanded, Secure: ax.Secure(),
		Actions: common.Uniq(common.Map(ax.Actions, func(action accessibility.CustomAction) string { return action.Name })),
		node:    node,
	}
	for bit, name := range traits {
		if name != "" && ax.Traits&(1<<bit) != 0 {
			out.Traits = append(out.Traits, name)
		}
	}
	out.Role = role(ax, depth, out.Traits)
	if ax.Selection != nil {
		out.Selection = &[2]uint64{ax.Selection.Location, ax.Selection.Length}
	}
	// UIKit and WebKit report an empty field's placeholder as its value
	// (24B5110a UIKit.axbundle 0x18a048920, 0x18a04898c; 24B5110a
	// WebCore.axbundle 0x2467137f8, 0x246713ad0).
	if ax.Placeholder != "" && ax.Value == ax.Placeholder {
		out.Value = ""
	} else if out.Value != "" || ax.TextEntry() {
		out.ShownValue = &out.Value
	}
	if node.HasFrame() {
		frame := node.Frame
		out.Frame = new(rectArray(frame))
		if node.Shown() {
			out.Point = new(pointArray(node.Point))
			out.Partial = frame.Width*frame.Height-node.Visible.Width*node.Visible.Height > 1
		} else {
			out.OffScreen = true
		}
	}
	return out
}

// A web check box has the button automation type and the toggle trait, a
// Control Center toggle automation type 0 and the toggle trait, a tab bar's
// tab the button automation type and the tab button trait, and a web pop-up
// button the pop-up button trait without the button trait (iPhone18,2 and
// iPad17,1, iOS and iPadOS 27.2 24B115). Headers have the header trait with
// the StaticText automation type, as in Settings and SwiftUI forms, or with
// automation type 0, as a UIKit table's section header (iPhone18,2, iOS 27.2
// 24B115).
func role(ax accessibility.Element, depth int, elementTraits []string) string {
	if depth == 0 {
		return "application"
	}
	name := "other"
	kind := elementType(ax.Type)
	plain := kind == typeButton || kind <= typeOther
	switch {
	case plain && ax.Traits&traitRadioButton != 0:
		name = "radioButton"
	case plain && ax.Traits&traitTabButton != 0:
		name = "tab"
	case plain && ax.Traits&traitToggle != 0:
		name = "toggle"
	case kind > typeOther && kind < uint64(len(roles)):
		name = roles[kind]
	case ax.Traits&traitPopUpButton != 0:
		name = "popUpButton"
	}
	if (name == "other" || name == "text") && slices.Contains(elementTraits, "header") {
		return "heading"
	}
	if name != "other" {
		return name
	}
	for _, it := range traitRoles {
		if slices.Contains(elementTraits, it.trait) {
			return it.role
		}
	}
	return name
}

func raw(node *deviceserver.PhoneNode, depth int) *element {
	out := describe(node, depth)
	out.Class = node.AX.Class
	for _, child := range node.Children {
		out.Children = append(out.Children, raw(child, depth+1))
	}
	return out
}

func shape(node *deviceserver.PhoneNode, depth int, system bool) []*element {
	out := describe(node, depth)
	ax := node.AX
	if elementType(ax.Type) == typeKeyboard && node.HasFrame() && !node.Shown() {
		return nil
	}
	var children []*element
	for _, child := range node.Children {
		children = append(children, shape(child, depth+1, system)...)
	}
	// A table lists its cells in a scroll view of its own, beside its section
	// headers (iPhone18,2 and iPad17,1, iOS and iPadOS 27.2 24B115).
	if slices.Contains(scrollingRoles, out.Role) {
		children = common.FlatMap(children, func(child *element) []*element {
			if child.Role != "scrollView" || child.Label != "" || child.node.AX.AccessibilityElement || adds(child, out) {
				return []*element{child}
			}
			return child.Children
		})
	}
	if ax.AccessibilityElement {
		children = slices.DeleteFunc(children, func(child *element) bool {
			return !child.node.AX.AccessibilityElement && len(child.Children) == 0 && !child.Focused
		})
	}
	if len(children) == 1 {
		child := children[0]
		switch {
		case out.Label != "" && child.Role != out.Role && (sameText(child.Label, out.Label) || child.Label == "" && sameText(child.Value, out.Label)) &&
			(isControl(out.Role) || isControl(child.Role)):
			switch {
			case isControl(out.Role) && !adds(child, out):
				children = child.Children
			case !adds(out, child):
				out, children = child, child.Children
			}
		case child.Role == out.Role && (out.Label == "" || sameText(child.Label, out.Label)):
			switch {
			case ax.AccessibilityElement && !adds(child, out):
				children = child.Children
			case !ax.AccessibilityElement && !adds(out, child):
				out, children = child, child.Children
			}
		}
	}
	out.Children = children
	ax = out.node.AX
	if len(children) == 0 && out.node.HasFrame() && (ax.Frame.Width == 0 || ax.Frame.Height == 0) {
		return nil
	}
	if ax.AccessibilityElement || depth == 0 {
		return []*element{out}
	}
	// SpringBoard shows every application in a card of its switcher, labeled
	// with the application's name, which holds the status bar (iPhone18,2, iOS
	// 27.2 24B115).
	labeled := (out.Label != "" || out.Identifier != "" && out.Role != "image" || out.Value != "") &&
		!(system && slices.Contains(genericRoles, out.Role))
	container := !slices.Contains(contentRoles, out.Role) && !isControl(out.Role) || !labeled && len(children) > 0
	switch {
	case len(children) == 0 && (container || !labeled && !isControl(out.Role)):
		return nil
	case slices.Contains(structuralRoles, out.Role), out.Role == "scrollView", out.Role == "cell" && len(children) > 1:
	case container && len(children) == 1 && (children[0].Label == out.Label || out.Label == "") && !adds(out, children[0]):
		return children
	case !labeled && container && !out.Focused && !out.Selected && out.Hint == "" && out.URL == "" && len(out.Actions) == 0:
		return children
	}
	return []*element{out}
}

func adds(dropped, kept *element) bool {
	return dropped.Identifier != "" && dropped.Identifier != kept.Identifier || dropped.Value != "" && dropped.Value != kept.Value ||
		dropped.Hint != "" && dropped.Hint != kept.Hint || dropped.URL != "" && dropped.URL != kept.URL ||
		dropped.Selected && !kept.Selected || dropped.Focused && !kept.Focused ||
		!common.All(dropped.Actions, func(action string) bool { return slices.Contains(kept.Actions, action) })
}

// Language & Region labels a row "Number Format, 1, 234, 567.89" and the
// button inside it "Number Format, 1,234,567.89" (iPhone18,2, iOS 27.0.1
// 24A446).
func sameText(first, second string) bool {
	plain := func(text string) string {
		return strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) || unicode.IsPunct(r) {
				return -1
			}
			return unicode.ToLower(r)
		}, text)
	}
	return first != "" && plain(first) == plain(second)
}

func isControl(role string) bool {
	return !slices.Contains(contentRoles, role) && !slices.Contains(genericRoles, role) &&
		!slices.Contains(structuralRoles, role) && role != "cell" && role != "scrollView"
}

func rectArray(rect deviceserver.Rect) [4]float64 {
	return [4]float64{tenth(rect.X), tenth(rect.Y), tenth(rect.Width), tenth(rect.Height)}
}

func pointArray(point deviceserver.Point) [2]float64 {
	return [2]float64{tenth(point.X), tenth(point.Y)}
}

func tenth(value float64) float64 {
	return math.Round(value*10) / 10
}
