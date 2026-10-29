//go:build darwin && cgo

package phonemcp

import (
	"maps"
	"slices"
	"strings"
	"unicode"

	"github.com/sagernet/sing/common"
)

const (
	headerStart = "// ==Workflow=="
	headerEnd   = "// ==/Workflow=="
)

var headerKeys = []string{"name", "version", "color", "symbol", "updateURL"}

type Header struct {
	Name      string
	Names     map[string]string
	Version   string
	Icon      Icon
	UpdateURL string
}

func splitHeader(source string) (lines []string, body string, found bool) {
	text := strings.TrimLeft(strings.TrimPrefix(source, "\uFEFF"), " \t\r\n")
	all := strings.SplitAfter(text, "\n")
	if strings.TrimSpace(all[0]) != headerStart {
		return nil, source, false
	}
	for index := 1; index < len(all); index++ {
		if strings.TrimSpace(all[index]) == headerEnd {
			for _, line := range all[1:index] {
				lines = append(lines, strings.TrimRight(line, "\r\n"))
			}
			return lines, strings.Join(all[index+1:], ""), true
		}
	}
	return nil, source, false
}

func HeaderTruncated(source string) bool {
	_, _, found := splitHeader(source)
	return !found && strings.HasPrefix(strings.TrimLeft(strings.TrimPrefix(source, "\uFEFF"), " \t\r\n"), headerStart)
}

func headerField(line string) (key string, value string, ok bool) {
	text, found := strings.CutPrefix(strings.TrimSpace(line), "//")
	if !found {
		return "", "", false
	}
	text, found = strings.CutPrefix(strings.TrimSpace(text), "@")
	if !found {
		return "", "", false
	}
	end := strings.IndexFunc(text, unicode.IsSpace)
	if end < 0 {
		return text, "", text != ""
	}
	return text[:end], strings.TrimSpace(text[end:]), true
}

func ReadHeader(source string) Header {
	header := Header{Names: make(map[string]string), Icon: DefaultIcon}
	lines, _, _ := splitHeader(source)
	for _, line := range lines {
		key, value, ok := headerField(line)
		if !ok {
			continue
		}
		if language, localized := strings.CutPrefix(key, "name:"); localized {
			if language != "" {
				header.Names[language] = value
			}
			continue
		}
		switch key {
		case "name":
			header.Name = value
		case "version":
			header.Version = value
		case "updateURL":
			header.UpdateURL = value
		case "color":
			header.Icon.Color = value
		case "symbol":
			header.Icon.Symbol = value
		}
	}
	if header.Icon.Check() != nil {
		header.Icon = DefaultIcon
	}
	return header
}

func WriteHeader(source string, header Header) string {
	lines, body, found := splitHeader(source)
	if !found {
		body = "\n" + source
	}
	fields := [][2]string{{"name", header.Name}}
	for _, language := range slices.Sorted(maps.Keys(header.Names)) {
		fields = append(fields, [2]string{"name:" + language, header.Names[language]})
	}
	fields = append(fields, [2]string{"version", header.Version}, [2]string{"color", header.Icon.Color},
		[2]string{"symbol", header.Icon.Symbol}, [2]string{"updateURL", header.UpdateURL})
	fields = common.Filter(fields, func(it [2]string) bool { return it[1] != "" })
	width := len(common.MaxBy(fields, func(it [2]string) int { return len(it[0]) })[0])
	out := common.Map(fields, func(it [2]string) string {
		return "// @" + it[0] + strings.Repeat(" ", width-len(it[0])+1) + it[1]
	})
	for _, line := range lines {
		key, _, ok := headerField(line)
		if !ok || !slices.Contains(headerKeys, key) && !strings.HasPrefix(key, "name:") {
			out = append(out, line)
		}
	}
	return headerStart + "\n" + strings.Join(append(out, headerEnd), "\n") + "\n" + body
}
