package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"howett.net/plist"
)

func writeScreenshotProfile(ctx context.Context, device captureDevice, deviceType, profiles, jobName string) (string, error) {
	output, err := simulatorCommand(ctx, "list", "devicetypes", "--json")
	if err != nil {
		return "", err
	}
	var list struct {
		DeviceTypes []struct {
			Identifier string
			BundlePath string
		}
	}
	if err := json.Unmarshal(output, &list); err != nil {
		return "", err
	}
	displayType := "com.apple.CoreSimulator.SimDeviceType." + device.displayType
	var source, displaySource string
	for _, entry := range list.DeviceTypes {
		switch entry.Identifier {
		case deviceType:
			source = entry.BundlePath
		case displayType:
			displaySource = entry.BundlePath
		}
	}
	if source == "" || displaySource == "" {
		return "", fmt.Errorf("missing simulator device profiles for %s", device.name)
	}

	// CoreSimulator only sees this directory after its private profile is complete.
	destination := filepath.Join(profiles, "DeviceTypes", device.name+".simdevicetype")
	if err := os.CopyFS(destination, os.DirFS(source)); err != nil {
		return "", err
	}
	identifier := "io.nekohasekai.swipterm.screenshots." + jobName
	infoPath := filepath.Join(destination, "Contents", "Info.plist")
	info, err := readScreenshotPlist(infoPath)
	if err != nil {
		return "", err
	}
	info["CFBundleIdentifier"] = identifier
	info["CFBundleName"] = captureDeviceName + jobName
	if err = writeScreenshotPlist(infoPath, info); err != nil {
		return "", err
	}
	if err = copyDisplayCapabilities(destination, displaySource); err != nil {
		return "", fmt.Errorf("configure %s display profile: %w", device.name, err)
	}
	return identifier, nil
}

func copyDisplayCapabilities(destination, source string) error {
	capabilitiesPath := filepath.Join(destination, "Contents", "Resources", "capabilities.plist")
	capabilities, err := readScreenshotPlist(capabilitiesPath)
	if err != nil {
		return err
	}
	displayCapabilities, err := readScreenshotPlist(filepath.Join(source, "Contents", "Resources", "capabilities.plist"))
	if err != nil {
		return err
	}
	caps, ok := capabilities["capabilities"].(map[string]any)
	displayCaps, displayOK := displayCapabilities["capabilities"].(map[string]any)
	if !ok || !displayOK {
		return fmt.Errorf("missing capabilities dictionary")
	}
	// CoreSimulator uses displays for the framebuffer. UIKit also uses the screen dimensions and artwork traits.
	for _, key := range []string{"displays", "ScreenDimensionsCapability", "subtype", "IsLargeFormatPhone", "HomeButtonType"} {
		if value, exists := displayCaps[key]; exists {
			caps[key] = value
		} else {
			delete(caps, key)
		}
	}
	artwork, ok := caps["ArtworkTraits"].(map[string]any)
	displayArtwork, displayOK := displayCaps["ArtworkTraits"].(map[string]any)
	if !ok || !displayOK {
		return fmt.Errorf("missing artwork traits dictionary")
	}
	for _, key := range []string{"ArtworkDeviceSubType", "ArtworkDeviceScaleFactor"} {
		artwork[key] = displayArtwork[key]
	}
	return writeScreenshotPlist(capabilitiesPath, capabilities)
}

func readScreenshotPlist(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var content map[string]any
	if _, err := plist.Unmarshal(data, &content); err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return content, nil
}

func writeScreenshotPlist(path string, content map[string]any) error {
	data, err := plist.Marshal(content, plist.XMLFormat)
	if err != nil {
		return fmt.Errorf("encode %s: %w", path, err)
	}
	return os.WriteFile(path, data, 0o644)
}
