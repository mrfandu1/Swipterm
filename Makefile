SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

build_ios:
	xcodebuild build -skipMacroValidation -scheme Swipterm -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_ios_simulator:
	xcodebuild build -skipMacroValidation -scheme Swipterm -configuration Debug -destination 'generic/platform=iOS Simulator' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

fmt:
	swiftformat Swipterm

.PHONY: build_ios build_ios_simulator fmt
