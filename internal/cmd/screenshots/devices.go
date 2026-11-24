package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
)

type captureSize struct {
	width  int
	height int
}

type captureDevice struct {
	name        string
	deviceType  string
	displayType string
	orientation string
	pose        string
	sizes       []captureSize
}

const captureDeviceName = "Swipterm Screenshots "

// The first size is the simulator's native resolution. The other sizes are
// accepted alternatives for the same display class in App Store Connect.
var devices = []captureDevice{
	{name: "iphone", deviceType: "iPhone-17-Pro", orientation: "portrait", sizes: []captureSize{{1206, 2622}, {1179, 2556}}},
	{name: "iphone-large", deviceType: "iPhone-17-Pro-Max", orientation: "portrait", sizes: []captureSize{{1320, 2868}, {1290, 2796}, {1260, 2736}}},
	{name: "iphone-faceid-large", deviceType: "iPhone-14-Plus", orientation: "portrait", sizes: []captureSize{{1284, 2778}, {1242, 2688}}},
	{name: "iphone-faceid-medium", deviceType: "iPhone-14", orientation: "portrait", sizes: []captureSize{{1170, 2532}, {1125, 2436}, {1080, 2340}}},
	{name: "iphone-home-large", deviceType: "iPhone-SE-3rd-generation", displayType: "iPhone-8-Plus", orientation: "portrait", sizes: []captureSize{{1242, 2208}}},
	{name: "iphone-home-medium", deviceType: "iPhone-SE-3rd-generation", orientation: "portrait", sizes: []captureSize{{750, 1334}}},
	{name: "iphone-4", deviceType: "iPhone-SE-3rd-generation", displayType: "iPhone-SE", orientation: "portrait", sizes: []captureSize{{640, 1136}}},
	{name: "duo-inner", deviceType: "iPhone-Duo", orientation: "portrait", pose: "open", sizes: []captureSize{{2007, 2853}}},
	{name: "duo-outer", deviceType: "iPhone-Duo", orientation: "portrait", pose: "closed", sizes: []captureSize{{1398, 2034}}},
	{name: "ipad", deviceType: "iPad-Pro-13-inch-M5-12GB", orientation: "landscapeLeft", sizes: []captureSize{{2752, 2064}, {2732, 2048}}},
	{name: "ipad-12.9", deviceType: "iPad-Pro-12-9-inch-6th-generation-8GB", orientation: "landscapeLeft", sizes: []captureSize{{2732, 2048}}},
	{name: "ipad-11", deviceType: "iPad-Pro-11-inch-M5-12GB", orientation: "landscapeLeft", sizes: []captureSize{{2420, 1668}, {2388, 1668}, {2360, 1640}, {2266, 1488}, {2316, 1512}}},
	{name: "ipad-10.5", deviceType: "iPad-Air--3rd-generation-", orientation: "landscapeLeft", sizes: []captureSize{{2224, 1668}}},
	{name: "ipad-9.7", deviceType: "iPad-mini--5th-generation-", orientation: "landscapeLeft", sizes: []captureSize{{2048, 1536}}},
}

type captureSimulator struct {
	udid string
	name string
}

type simulatorDevice struct {
	UDID                 string
	Name                 string
	State                string
	IsAvailable          bool
	DeviceTypeIdentifier string
	DataPath             string
}

type simulatorRuntime struct {
	Identifier           string
	Platform             string
	Version              string
	IsAvailable          bool
	SupportedDeviceTypes []struct{ Identifier string }
}

func simulatorCommand(args ...string) ([]byte, error) {
	result, err := exec.Command("xcrun", append([]string{"simctl"}, args...)...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("simctl %s: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(result)))
	}
	return result, nil
}

func listCaptureSimulators(profiles string) (map[string][]simulatorDevice, error) {
	args := []string{"list", "--json", "devices"}
	if profiles != "" {
		args = append([]string{"--profiles", profiles}, args...)
	}
	output, err := simulatorCommand(args...)
	if err != nil {
		return nil, err
	}
	var list struct{ Devices map[string][]simulatorDevice }
	if err := json.Unmarshal(output, &list); err != nil {
		return nil, err
	}
	return list.Devices, nil
}

func latestRuntime(deviceType string) (string, error) {
	output, err := simulatorCommand("list", "--json", "runtimes")
	if err != nil {
		return "", err
	}
	var list struct{ Runtimes []simulatorRuntime }
	if err := json.Unmarshal(output, &list); err != nil {
		return "", err
	}
	var latest simulatorRuntime
	for _, runtime := range list.Runtimes {
		if runtime.Platform != "iOS" || !runtime.IsAvailable {
			continue
		}
		supported := slices.ContainsFunc(runtime.SupportedDeviceTypes, func(device struct{ Identifier string }) bool {
			return device.Identifier == deviceType
		})
		if supported && (latest.Identifier == "" || compareRuntimeVersions(runtime.Version, latest.Version) > 0) {
			latest = runtime
		}
	}
	if latest.Identifier == "" {
		return "", fmt.Errorf("no installed iOS simulator runtime supports %s", deviceType)
	}
	return latest.Identifier, nil
}

func compareRuntimeVersions(first, second string) int {
	var lhs, rhs [3]int
	fmt.Sscanf(first, "%d.%d.%d", &lhs[0], &lhs[1], &lhs[2])
	fmt.Sscanf(second, "%d.%d.%d", &rhs[0], &rhs[1], &rhs[2])
	return slices.Compare(lhs[:], rhs[:])
}

func prepareSimulator(device captureDevice) (captureSimulator, error) {
	deviceType := "com.apple.CoreSimulator.SimDeviceType." + device.deviceType
	runtime, err := latestRuntime(deviceType)
	if err != nil {
		return captureSimulator{}, err
	}
	deviceType, profiles, err := screenshotDeviceProfile(device, deviceType)
	if err != nil {
		return captureSimulator{}, err
	}
	simulators, err := listCaptureSimulators(profiles)
	if err != nil {
		return captureSimulator{}, err
	}
	name := captureDeviceName + device.name
	findSimulator := func() (simulatorDevice, bool) {
		for _, simulator := range simulators[runtime] {
			if simulator.Name == name && simulator.IsAvailable && simulator.DeviceTypeIdentifier == deviceType {
				return simulator, true
			}
		}
		return simulatorDevice{}, false
	}
	simulator, found := findSimulator()
	if !found {
		args := []string{"create", name, deviceType, runtime}
		if profiles != "" {
			args = append([]string{"--profiles", profiles}, args...)
		}
		if _, err := simulatorCommand(args...); err != nil {
			return captureSimulator{}, err
		}
		simulators, err = listCaptureSimulators(profiles)
		if err != nil {
			return captureSimulator{}, err
		}
		simulator, found = findSimulator()
		if !found {
			return captureSimulator{}, fmt.Errorf("created simulator %q is missing from simctl list", name)
		}
	}
	if err := configureSimulatorPreferences(device, simulator); err != nil {
		return captureSimulator{}, err
	}
	return captureSimulator{udid: simulator.UDID, name: name}, nil
}

func configureSimulatorPreferences(device captureDevice, simulator simulatorDevice) error {
	preferences := map[string]map[string]any{
		".GlobalPreferences": {"AppleLanguages": []any{"en-US"}, "AppleLocale": "en_US"},
	}
	if strings.HasPrefix(device.deviceType, "iPad-") {
		// Use Full Screen Apps and remove the window grabber on iPad.
		preferences["com.apple.springboard"] = map[string]any{
			"SBMedusaMultitaskingEnabled": false,
			"SBChamoisWindowingEnabled":   false,
		}
	}
	for domain, values := range preferences {
		path := filepath.Join(simulator.DataPath, "Library", "Preferences", domain+".plist")
		content, err := readScreenshotPlist(path)
		if errors.Is(err, os.ErrNotExist) {
			content = make(map[string]any)
		} else if err != nil {
			return err
		}
		changed := false
		for key, value := range values {
			if !reflect.DeepEqual(content[key], value) {
				content[key] = value
				changed = true
			}
		}
		if !changed {
			continue
		}
		if simulator.State != "Shutdown" {
			return fmt.Errorf("shut down %q before updating screenshot preferences", simulator.Name)
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := writeScreenshotPlist(path, content); err != nil {
			return err
		}
	}
	return nil
}

func shutdownCaptureSimulator(simulator captureSimulator) error {
	if !strings.HasPrefix(simulator.name, captureDeviceName) {
		return fmt.Errorf("%q is not a Swipterm screenshots simulator", simulator.name)
	}
	_, err := simulatorCommand("shutdown", simulator.udid)
	if err != nil && strings.Contains(err.Error(), "current state: Shutdown") {
		return nil
	}
	return err
}
