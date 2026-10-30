package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
)

const (
	sourceMapSuffix = ".map"
	vlqAlphabet     = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
)

type segment struct {
	column, source, line, sourceColumn int
}

type sourceMap struct {
	sources []string
	lines   [][]segment
}

func loadSourceMap(name string) (*sourceMap, error) {
	data, err := os.ReadFile(name)
	if err != nil {
		return nil, err
	}
	var raw struct {
		SourceRoot string   `json:"sourceRoot"`
		Sources    []string `json:"sources"`
		Mappings   string   `json:"mappings"`
	}
	if err = json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	directory := filepath.Dir(name)
	working, _ := os.Getwd()
	out := &sourceMap{sources: make([]string, len(raw.Sources))}
	for index, source := range raw.Sources {
		resolved := filepath.Join(directory, raw.SourceRoot, filepath.FromSlash(source))
		if relative, err := filepath.Rel(working, resolved); err == nil && !strings.HasPrefix(relative, "..") {
			resolved = relative
		}
		out.sources[index] = resolved
	}
	var source, line, column int
	for _, text := range strings.Split(raw.Mappings, ";") {
		var segments []segment
		generated := 0
		for _, field := range strings.Split(text, ",") {
			if field == "" {
				continue
			}
			values, err := decodeVLQ(field)
			if err != nil {
				return nil, err
			}
			generated += values[0]
			item := segment{column: generated, source: -1}
			if len(values) >= 4 {
				source, line, column = source+values[1], line+values[2], column+values[3]
				item.source, item.line, item.sourceColumn = source, line, column
			}
			segments = append(segments, item)
		}
		out.lines = append(out.lines, segments)
	}
	return out, nil
}

func decodeVLQ(text string) ([]int, error) {
	var values []int
	value, shift := 0, 0
	for _, char := range text {
		digit := strings.IndexRune(vlqAlphabet, char)
		if digit < 0 {
			return nil, E.New("the source map holds the character ", strconv.QuoteRune(char), " in its mappings")
		}
		value += (digit & 31) << shift
		if digit&32 != 0 {
			shift += 5
			continue
		}
		if value&1 != 0 {
			values = append(values, -(value >> 1))
		} else {
			values = append(values, value>>1)
		}
		value, shift = 0, 0
	}
	return values, nil
}

func (m *sourceMap) lookup(line, column int) (string, int, int, bool) {
	if line < 1 || line > len(m.lines) {
		return "", 0, 0, false
	}
	segments := m.lines[line-1]
	index := sort.Search(len(segments), func(index int) bool { return segments[index].column > column-1 }) - 1
	if index < 0 || segments[index].source < 0 || segments[index].source >= len(m.sources) {
		return "", 0, 0, false
	}
	found := segments[index]
	return m.sources[found.source], found.line + 1, found.sourceColumn + 1, true
}

type sourceMaps struct {
	access sync.Mutex
	root   string
	loaded map[string]map[string]*sourceMap
}

var sources = &sourceMaps{loaded: make(map[string]map[string]*sourceMap)}

func (s *sourceMaps) forSwiplet(id string) map[string]*sourceMap {
	s.access.Lock()
	defer s.access.Unlock()
	if s.root == "" {
		return nil
	}
	if found, cached := s.loaded[id]; cached {
		return found
	}
	found := make(map[string]*sourceMap)
	if p, err := loadProject(s.root); err == nil && p.id == id {
		directory := filepath.Join(p.root, "dist", id, "src")
		names, _ := filepath.Glob(filepath.Join(directory, "*"+sourceMapSuffix))
		for _, name := range names {
			if loaded, err := loadSourceMap(name); err == nil {
				found[strings.TrimSuffix(filepath.Base(name), sourceMapSuffix)] = loaded
			}
		}
	}
	s.loaded[id] = found
	return found
}

func (s *sourceMaps) forget(id string) {
	s.access.Lock()
	delete(s.loaded, id)
	s.access.Unlock()
}

func (s *sourceMaps) frame(id string) func(*swiptv1.StackFrame) *swiptv1.StackFrame {
	return func(frame *swiptv1.StackFrame) *swiptv1.StackFrame {
		found := s.forSwiplet(id)[frame.File]
		if found == nil {
			return frame
		}
		file, line, column, mapped := found.lookup(int(frame.Line), int(frame.Column))
		if !mapped {
			return frame
		}
		return &swiptv1.StackFrame{Function: frame.Function, File: file, Line: uint32(line), Column: uint32(column)}
	}
}
