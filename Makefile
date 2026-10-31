SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

lib:
	go run ./internal/cmd/build_libswipt

proto:
	go run ./internal/cmd/protogen
	gofumpt -w internal/proto

proto_install:
	go install -v google.golang.org/protobuf/cmd/protoc-gen-go@latest
	go install -v google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

RUNTIME := internal/automation/runtime
RUNTIME_BUNDLE := build/runtime/main.jsbundle
RUNTIME_BUNDLE_INPUTS := $(shell find $(RUNTIME)/src/app $(RUNTIME)/src/shared $(RUNTIME)/patches -type f) $(RUNTIME)/package.json $(RUNTIME)/app.json package.json bun.lock

lib_react:
	bun install --frozen-lockfile
	node node_modules/react-native/scripts/setup-apple-spm.js update --product-name Swipt --yes

$(RUNTIME_BUNDLE): $(RUNTIME_BUNDLE_INPUTS)
	mkdir -p build/runtime
	cd $(RUNTIME) && CI=1 bun expo export:embed --platform ios --dev false --minify false --entry-file src/app/index.tsx --bundle-output ../../../build/runtime/main.js --assets-dest ../../../build/runtime/assets
	node_modules/hermes-compiler/hermesc/osx-bin/hermesc -emit-binary -O -w -out $@ build/runtime/main.js

runtime_bundle: $(RUNTIME_BUNDLE)

runtime:
	bun install --frozen-lockfile
	cd $(RUNTIME) && bun build.mjs

build_ios: runtime_bundle
	xcodebuild build -skipMacroValidation -scheme Swipt -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_ios_ipa: lib lib_react archive_ios_ipa

archive_ios_ipa: runtime_bundle
	rm -rf build/Swipt-iOS.xcarchive build/Payload build/Swipt.ipa
	xcodebuild archive -skipMacroValidation $(XCODEBUILD_FLAGS) -scheme Swipt -configuration Release -destination 'generic/platform=iOS' -archivePath build/Swipt-iOS.xcarchive \
		CODE_SIGNING_ALLOWED=NO | xcbeautify
	mkdir build/Payload
	cp -R build/Swipt-iOS.xcarchive/Products/Applications/Swipt.app build/Payload/
	cd build && zip -qry Swipt.ipa Payload
	rm -rf build/Payload

altstore_icon:
	rm -rf build/altstore
	mkdir -p build/altstore
	"$$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" Swipt/Resources/AppIcon.icon \
		--export-image --output-file build/altstore/icon.png --platform iOS --rendition Default --width 568 --height 568 --scale 1 > /dev/null
	# AltStore draws icons on a white background, clipped to a circle or a height/5 corner radius
	# (AltStore fafd76e, AltStore/Components/AppIconImageView.swift:46-65), so the transparent
	# corners and edge highlight of the exported squircle show up as a white border.
	sips --cropToHeightWidth 512 512 build/altstore/icon.png > /dev/null

altstore_source: altstore_icon
	go run ./internal/cmd/build_altstore_source

build_macos:
	xcodebuild build -skipMacroValidation -scheme 'Swipt macOS' -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

fmt:
	gofumpt -l -w libswipt internal
	go run ./internal/cmd/format_xcstrings $$(find Swipt -name '*.xcstrings')
