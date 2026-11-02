SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

lib:
	go run ./internal/cmd/build_libswipt

fmt:
	gofumpt -l -w libswipt internal
	go run ./internal/cmd/format_xcstrings $$(find Swipt -name '*.xcstrings')
