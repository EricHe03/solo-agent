package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/swipt-automation/swipt/internal/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func enumText(value protoreflect.Enum, prefix string) string {
	name := strings.TrimPrefix(string(value.Descriptor().Values().ByNumber(value.Number()).Name()), prefix)
	return strings.ReplaceAll(strings.ToLower(name), "_", " ")
}

func levelName(level proto.LogLevel) string {
	if level == proto.LogLevel_LOG_LEVEL_UNSPECIFIED {
		return "info"
	}
	return enumText(level, "LOG_LEVEL_")
}

func clockTime(at time.Time) string {
	return at.Local().Format("15:04:05.000")
}

func frameText(frame *proto.StackFrame) string {
	position := frame.File + ":" + strconv.FormatUint(uint64(frame.Line), 10) + ":" + strconv.FormatUint(uint64(frame.Column), 10)
	if frame.Function == "" {
		return position
	}
	return frame.Function + " (" + position + ")"
}

func failureText(failure *proto.ScriptError, frames func(*proto.StackFrame) *proto.StackFrame) string {
	text := failure.Name + ": " + failure.Message
	for _, frame := range failure.Stack {
		text += "\n    at " + frameText(frames(frame))
	}
	return text
}

func printScriptError(failure *proto.ScriptError, frames func(*proto.StackFrame) *proto.StackFrame) error {
	fmt.Fprintln(os.Stderr, "error: "+failureText(failure, frames))
	return falseResult{}
}

func printLog(entry *proto.LogEntry, toStdout bool) {
	message := entry.Message
	if entry.Tag != "" {
		message = entry.Tag + ": " + message
	}
	output := os.Stderr
	if toStdout {
		output = os.Stdout
	}
	fmt.Fprintln(output, clockTime(entry.Time.AsTime()), strings.ToUpper(levelName(entry.Level)), message)
}

func serviceText(id string, state *proto.ServiceState) string {
	text := "disabled"
	if state.GetEnabled() {
		text = "enabled"
	}
	status := "stopped"
	if state.GetStatus() != proto.ServiceStatus_SERVICE_STATUS_UNSPECIFIED {
		status = enumText(state.Status, "SERVICE_STATUS_")
	}
	text += ", " + status
	if state.GetSince() != nil {
		text += " since " + clockTime(state.Since.AsTime())
	}
	if state.GetError() != nil {
		text += ": " + failureText(state.Error, sources.frame(id))
	}
	return text
}

func printService(id string, state *proto.ServiceState) {
	fmt.Println(id + ": " + serviceText(id, state))
}
