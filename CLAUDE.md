# swipt

## Introduction

@README.md

## Commands

`bun dev` prints every development command with its arguments; `swipt [COMMAND...] --help` does the same for the CLI.

* `bun dev install [-d NAME|URL]` - Build Swipt, install it on the device, launch it, and check the installed build
* `bun dev build [ios|macos]` - Build the Debug app into build/DerivedData
* `bun dev lib` - Build the SDK runtime and libswipt
* `bun dev ui` - Bundle the Swiplet UI runtime
* `bun dev ipa` - Build Swipt.ipa
* `bun dev proto` - Regenerate the gRPC code
* `make fmt` - Format Go and string catalogs
