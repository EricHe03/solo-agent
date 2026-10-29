SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

lib:
	go run ./cmd/internal/build_libswipt

build_ios:
	xcodebuild build -skipMacroValidation -scheme Swipt -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_ios_ipa: lib archive_ios_ipa

archive_ios_ipa:
	rm -rf build/Swipt-iOS.xcarchive build/Payload build/Swipt.ipa
	xcodebuild archive -skipMacroValidation $(XCODEBUILD_FLAGS) -scheme Swipt -configuration Release -destination 'generic/platform=iOS' -archivePath build/Swipt-iOS.xcarchive \
		CODE_SIGNING_ALLOWED=NO | xcbeautify
	mkdir build/Payload
	cp -R build/Swipt-iOS.xcarchive/Products/Applications/Swipt.app build/Payload/
	cd build && zip -qry Swipt.ipa Payload
	rm -rf build/Payload

altstore_source:
	rm -rf build/altstore
	mkdir -p build/altstore
	"$$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" Swipt/Resources/AppIcon.icon \
		--export-image --output-file build/altstore/icon.png --platform iOS --rendition Default --width 568 --height 568 --scale 1 > /dev/null
	# AltStore draws icons on a white background, clipped to a circle or a height/5 corner radius
	# (AltStore fafd76e, AltStore/Components/AppIconImageView.swift:46-65), so the transparent
	# corners and edge highlight of the exported squircle show up as a white border.
	sips --cropToHeightWidth 512 512 build/altstore/icon.png > /dev/null
	go run ./cmd/internal/build_altstore_source

build_macos:
	xcodebuild build -skipMacroValidation -scheme Swipt -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

fmt:
	gofumpt -l -w cmd libswipt internal
	go run ./cmd/internal/format_xcstrings $$(find Swipt -name '*.xcstrings')
