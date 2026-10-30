package main

import (
	"bufio"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type ignoreRule struct {
	base      string
	pattern   *regexp.Regexp
	negated   bool
	directory bool
}

type ignorer struct {
	rules []ignoreRule
}

func excluded(name string) bool {
	return strings.HasPrefix(name, ".") || name == "node_modules" || name == "dist"
}

func loadIgnorer(root string) *ignorer {
	i := &ignorer{}
	_ = filepath.WalkDir(root, func(name string, entry fs.DirEntry, err error) error {
		if err != nil || !entry.IsDir() {
			return nil
		}
		relative := relativePath(root, name)
		if relative != "" && i.ignored(relative, true) {
			return filepath.SkipDir
		}
		i.read(filepath.Join(name, ".gitignore"), relative)
		return nil
	})
	return i
}

func relativePath(root, name string) string {
	relative, err := filepath.Rel(root, name)
	if err != nil || relative == "." {
		return ""
	}
	return filepath.ToSlash(relative)
}

func (i *ignorer) read(name, base string) {
	file, err := os.Open(name)
	if err != nil {
		return
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		if rule, valid := parseIgnoreRule(scanner.Text()); valid {
			rule.base = base
			i.rules = append(i.rules, rule)
		}
	}
}

func parseIgnoreRule(line string) (ignoreRule, bool) {
	var rule ignoreRule
	line = strings.TrimRight(line, " \t\r")
	if line == "" || strings.HasPrefix(line, "#") {
		return rule, false
	}
	switch {
	case strings.HasPrefix(line, "!"):
		rule.negated, line = true, line[1:]
	case strings.HasPrefix(line, `\`):
		line = line[1:]
	}
	if strings.HasSuffix(line, "/") {
		rule.directory, line = true, strings.TrimRight(line, "/")
	}
	if line == "" {
		return rule, false
	}
	anchored := strings.Contains(line, "/")
	line = strings.TrimPrefix(line, "/")
	var expression strings.Builder
	expression.WriteString("^")
	if !anchored {
		expression.WriteString("(?:.*/)?")
	}
	for index := 0; index < len(line); index++ {
		rest := line[index:]
		switch {
		case strings.HasPrefix(rest, "**/"):
			expression.WriteString("(?:.*/)?")
			index += 2
		case rest == "/**":
			expression.WriteString("/.*")
			index += 2
		case strings.HasPrefix(rest, "**"):
			expression.WriteString(".*")
			index++
		case rest[0] == '*':
			expression.WriteString("[^/]*")
		case rest[0] == '?':
			expression.WriteString("[^/]")
		case rest[0] == '[' && strings.IndexByte(rest[1:], ']') > 0:
			end := strings.IndexByte(rest[1:], ']')
			class := rest[1 : 1+end]
			if strings.HasPrefix(class, "!") {
				class = "^" + class[1:]
			}
			expression.WriteString("[" + strings.ReplaceAll(class, `\`, `\\`) + "]")
			index += end + 1
		case rest[0] == '\\' && len(rest) > 1:
			expression.WriteString(regexp.QuoteMeta(rest[1:2]))
			index++
		default:
			expression.WriteString(regexp.QuoteMeta(rest[:1]))
		}
	}
	expression.WriteString("$")
	pattern, err := regexp.Compile(expression.String())
	if err != nil {
		return rule, false
	}
	rule.pattern = pattern
	return rule, true
}

func (i *ignorer) ignored(relative string, directory bool) bool {
	parts := strings.Split(relative, "/")
	for index, part := range parts {
		if excluded(part) || i.matches(strings.Join(parts[:index+1], "/"), directory || index < len(parts)-1) {
			return true
		}
	}
	return false
}

func (i *ignorer) matches(relative string, directory bool) bool {
	ignored := false
	for _, rule := range i.rules {
		if rule.directory && !directory {
			continue
		}
		local := relative
		if rule.base != "" {
			var inside bool
			if local, inside = strings.CutPrefix(relative, rule.base+"/"); !inside {
				continue
			}
		}
		if rule.pattern.MatchString(local) {
			ignored = !rule.negated
		}
	}
	return ignored
}
