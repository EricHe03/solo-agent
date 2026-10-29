package accessibility

import (
	E "github.com/sagernet/sing/common/exceptions"
)

type Snapshot struct {
	Root   *TreeNode
	Remote []*TreeNode
	Listed map[ElementRef]bool
}

func snapshotNode(value any) (*TreeNode, map[string]any, map[any]any, error) {
	fields, _ := value.(map[string]any)
	object, ok := parseTranslation(fields["UIAccessibilitySnapshotKeyElement"])
	if !ok {
		return nil, nil, nil, E.New("accessibility: snapshot: a node has no element")
	}
	values, _ := fields["UIAccessibilitySnapshotKeyAttributes"].(map[any]any)
	return &TreeNode{Element: parseSnapshotElement(object, values)}, fields, values, nil
}

func buildSnapshot(value any) (*Snapshot, error) {
	seen := make(map[ElementRef]bool)
	var build func(value any) (*TreeNode, error)
	build = func(value any) (*TreeNode, error) {
		node, fields, _, err := snapshotNode(value)
		if err != nil {
			return nil, err
		}
		if seen[node.Ref] {
			return nil, nil
		}
		seen[node.Ref] = true
		children, _ := fields["UIAccessibilitySnapshotKeyChildren"].([]any)
		for _, value := range children {
			child, err := build(value)
			if err != nil {
				return nil, err
			}
			if child != nil {
				node.Children = append(node.Children, child)
			}
		}
		return node, nil
	}
	root, err := build(value)
	if err != nil {
		return nil, err
	}
	out := &Snapshot{Root: root, Listed: seen}
	var clip func(node *TreeNode, area LayoutFrame)
	clip = func(node *TreeNode, area LayoutFrame) {
		node.Clip = area
		switch {
		case hasArea(node.VisibleFrame):
			node.Clip = *node.VisibleFrame
		// A window's frame is in its own space, which differs from the
		// application's for SpringBoard: its application element is landscape
		// on a landscape iPad, while its windows and their content are portrait
		// (iPad17,1, iPadOS 27.2 24B115).
		case node.Type == automationWindow && hasArea(node.Frame):
			node.Clip = *node.Frame
		}
		if node.Class == remoteElementClass {
			out.Remote = append(out.Remote, node)
		}
		for _, child := range node.Children {
			clip(child, node.Clip)
		}
	}
	var area LayoutFrame
	if root.Frame != nil {
		area = *root.Frame
	}
	clip(root, area)
	return out, nil
}

func hasArea(frame *LayoutFrame) bool {
	return frame != nil && frame.Width > 0 && frame.Height > 0
}
