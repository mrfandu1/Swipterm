package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoveNewSimulatorAfterBootFailure(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SIM_FIXTURE", directory)
	const udid = "11111111-2222-3333-4444-555555555555"
	t.Setenv("SIM_UDID", udid)
	// The adapter simulates a create that writes a warning to stderr and a boot failure.
	// Real simulators and CoreSimulator preferences must never be touched by this test.
	const xcrun = `#!/bin/sh
set -eu
[ "$1" = simctl ]
shift
if [ "$1" = --profiles ]; then
    [ -d "$2/DeviceTypes" ]
    shift 2
fi
case "$1" in
    list)
        case "$*" in
            "list --json runtimes") echo '{"runtimes":[{"identifier":"iOS","platform":"iOS","version":"27.2","isAvailable":true,"supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.Test"}]}]}' ;;
            "list devicetypes --json") printf '{"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.Test","bundlePath":"%s/profile"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.Display","bundlePath":"%s/profile"}]}' "$SIM_FIXTURE" "$SIM_FIXTURE" ;;
            "list --json devices $SIM_UDID") printf '{"devices":{"iOS":[{"udid":"%s","dataPath":"%s/data"}]}}' "$SIM_UDID" "$SIM_FIXTURE" ;;
            *) exit 2 ;;
        esac ;;
    create) echo "warning" >&2; echo "$SIM_UDID" ;;
    bootstatus) echo "injected boot error" >&2; exit 1 ;;
    shutdown|delete) echo "$*" >> "$SIM_FIXTURE/cleanup" ;;
    *) exit 2 ;;
esac
`
	if err := os.WriteFile(filepath.Join(directory, "xcrun"), []byte(xcrun), 0o755); err != nil {
		t.Fatal(err)
	}
	contents := filepath.Join(directory, "profile", "Contents")
	if err := os.MkdirAll(filepath.Join(contents, "Resources"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeScreenshotPlist(filepath.Join(contents, "Info.plist"), map[string]any{"CFBundleName": "Test"}); err != nil {
		t.Fatal(err)
	}
	capabilities := map[string]any{"ArtworkTraits": map[string]any{"ArtworkDeviceSubType": 1, "ArtworkDeviceScaleFactor": 2}}
	if err := writeScreenshotPlist(filepath.Join(contents, "Resources", "capabilities.plist"), map[string]any{"capabilities": capabilities}); err != nil {
		t.Fatal(err)
	}
	jobDirectory := filepath.Join(directory, "iphone-test-1234")
	device := captureDevice{name: "iphone-test", deviceType: "Test", displayType: "Display"}
	_, err := prepareSimulator(t.Context(), device, jobDirectory)
	if err == nil || !strings.Contains(err.Error(), "injected boot error") {
		t.Fatalf("expected boot failure, got %v", err)
	}
	cleanup, err := os.ReadFile(filepath.Join(directory, "cleanup"))
	if err != nil || string(cleanup) != "shutdown "+udid+"\ndelete "+udid+"\n" {
		t.Fatalf("unexpected cleanup %q, %v", cleanup, err)
	}
	if _, err := os.Stat(filepath.Join(jobDirectory, "profiles")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temporary profile directory still exists: %v", err)
	}
}
