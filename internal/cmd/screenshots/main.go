package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
)

const (
	scheme        = "SwiptermScreenshots"
	derivedData   = "build/DerivedData-screenshots"
	buildProducts = derivedData + "/Build/Products"
	resultsPath   = "build/screenshots"
	outputPath    = "screenshots"
	catalogPath   = "Swipterm/Localizable.xcstrings"
)

var screenNames = []string{"01-Setup", "02-Terminal"}

type captureLanguage struct {
	id      string
	locales []string
}

type captureJob struct {
	device    captureDevice
	languages []captureLanguage
}

func main() {
	var deviceNames []string
	for _, device := range devices {
		deviceNames = append(deviceNames, device.name)
	}
	selectedDevices := flag.String("devices", strings.Join(deviceNames, ","), "comma-separated device names")
	selectedLanguages := flag.String("languages", "", "comma-separated app languages (default: all app languages)")
	parallel := flag.Int("parallel", 1, "maximum number of simulator test runs at once")
	skipBuild := flag.Bool("skip-build", false, "reuse previously built screenshot test products")
	resume := flag.Bool("resume", false, "reuse valid screenshots")
	flag.Parse()
	if flag.NArg() != 0 {
		log.Fatal("unexpected argument ", flag.Arg(0))
	}
	if *parallel < 1 {
		log.Fatal("-parallel must be positive")
	}
	if err := runScreenshots(*selectedDevices, *selectedLanguages, *parallel, *skipBuild, *resume); err != nil {
		log.Fatal(err)
	}
}

func runScreenshots(selectedDevices, selectedLanguages string, parallel int, skipBuild, resume bool) error {
	languages, err := selectLanguages(selectedLanguages)
	if err != nil {
		return err
	}
	var jobs []captureJob
	for _, name := range splitNames(selectedDevices) {
		index := slices.IndexFunc(devices, func(device captureDevice) bool { return device.name == name })
		if index < 0 {
			return fmt.Errorf("unknown device %q", name)
		}
		device := devices[index]
		pending := languages
		if resume {
			pending, err = remainingLanguages(device, languages)
			if err != nil {
				return err
			}
		}
		if len(pending) > 0 {
			jobs = append(jobs, captureJob{device: device, languages: pending})
		}
	}
	if len(jobs) == 0 {
		log.Print("all requested screenshots are present")
		return nil
	}
	if !skipBuild {
		log.Print("building Swipterm screenshot tests")
		err = runCommand(exec.Command("xcodebuild", "build-for-testing", "-quiet", "-scheme", scheme,
			"-destination", "generic/platform=iOS Simulator",
			"-derivedDataPath", derivedData,
			"-skipMacroValidation", "ARCHS=$(NATIVE_ARCH_ACTUAL)",
			"SWIFT_ACTIVE_COMPILATION_CONDITIONS=SWIPTERM_STORE_SCREENSHOTS",
		))
		if err != nil {
			return err
		}
	}
	testRun, err := findTestRun()
	if err != nil {
		return err
	}
	if err = os.MkdirAll(resultsPath, 0o755); err != nil {
		return err
	}
	results := make([]error, len(jobs))
	var workers sync.WaitGroup
	slots := make(chan struct{}, parallel)
	for index, job := range jobs {
		slots <- struct{}{}
		workers.Go(func() {
			defer func() { <-slots }()
			if err := captureScreenshots(testRun, job); err != nil {
				results[index] = fmt.Errorf("%s: %w", job.device.name, err)
				log.Print(results[index])
			}
		})
	}
	workers.Wait()
	return errors.Join(results...)
}

func splitNames(value string) []string {
	var names []string
	for _, name := range strings.Split(value, ",") {
		name = strings.TrimSpace(name)
		if !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	return names
}

func selectLanguages(selected string) ([]captureLanguage, error) {
	data, err := os.ReadFile(catalogPath)
	if err != nil {
		return nil, err
	}
	var catalog struct {
		SourceLanguage string `json:"sourceLanguage"`
		Strings        map[string]struct {
			Localizations map[string]json.RawMessage `json:"localizations"`
		} `json:"strings"`
	}
	if err = json.Unmarshal(data, &catalog); err != nil {
		return nil, fmt.Errorf("read %s: %w", catalogPath, err)
	}
	if catalog.SourceLanguage == "" {
		return nil, fmt.Errorf("%s has no source language", catalogPath)
	}
	known := map[string]bool{catalog.SourceLanguage: true}
	for _, entry := range catalog.Strings {
		for language := range entry.Localizations {
			known[language] = true
		}
	}
	ids := slices.Sorted(maps.Keys(known))
	if selected != "" {
		ids = splitNames(selected)
	}
	var languages []captureLanguage
	for _, id := range ids {
		if !known[id] {
			return nil, fmt.Errorf("unknown app language %q", id)
		}
		locales := []string{id}
		if id == "en" {
			locales = []string{"en-US", "en-GB", "en-CA", "en-AU"}
		}
		languages = append(languages, captureLanguage{id: id, locales: locales})
	}
	return languages, nil
}

func findTestRun() (string, error) {
	pattern := filepath.Join(buildProducts, scheme+"_*.xctestrun")
	paths, err := filepath.Glob(pattern)
	if err != nil {
		return "", err
	}
	var newest string
	var newestInfo os.FileInfo
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return "", err
		}
		if newestInfo == nil || info.ModTime().After(newestInfo.ModTime()) {
			newest, newestInfo = path, info
		}
	}
	if newest == "" {
		return "", fmt.Errorf("no screenshot test products at %s; run without -skip-build", pattern)
	}
	return filepath.Abs(newest)
}

func captureScreenshots(testRun string, job captureJob) (err error) {
	simulator, err := prepareSimulator(job.device)
	if err != nil {
		return err
	}
	defer func() {
		err = errors.Join(err, shutdownCaptureSimulator(simulator))
	}()
	directory, err := os.MkdirTemp(resultsPath, job.device.name+"-")
	if err != nil {
		return err
	}
	bundle := filepath.Join(directory, "Screenshots.xcresult")
	attachments := filepath.Join(directory, "attachments")
	log.Printf("capturing %s (%d languages)", job.device.name, len(job.languages))
	test := exec.Command("xcodebuild", "test-without-building", "-quiet", "-xctestrun", testRun,
		"-destination", "platform=iOS Simulator,id="+simulator.udid,
		"-resultBundlePath", bundle, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
	)
	var languages []string
	for _, language := range job.languages {
		languages = append(languages, language.id)
	}
	size := job.device.sizes[0]
	// xcodebuild strips TEST_RUNNER_ when forwarding variables to the UI test process.
	test.Env = append(test.Environ(),
		"TEST_RUNNER_SCREENSHOT_LANGUAGES="+strings.Join(languages, ","),
		"TEST_RUNNER_SCREENSHOT_ORIENTATION="+job.device.orientation,
		"TEST_RUNNER_SCREENSHOT_WIDTH="+strconv.Itoa(size.width),
		"TEST_RUNNER_SCREENSHOT_HEIGHT="+strconv.Itoa(size.height),
	)
	testErr := runCommand(test)
	var exportErr error
	if _, err = os.Stat(bundle); err == nil {
		exportErr = runCommand(exec.Command("xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", attachments))
		if exportErr == nil {
			exportErr = saveAttachments(job, attachments)
		}
	} else if testErr == nil {
		exportErr = err
	}
	if err = errors.Join(testErr, exportErr); err != nil {
		return fmt.Errorf("%w (results: %s)", err, directory)
	}
	log.Printf("saved %s screenshots", job.device.name)
	return os.RemoveAll(directory)
}

func runCommand(cmd *exec.Cmd) error {
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", cmd.Args[0], cmd.Args[1], err)
	}
	return nil
}

func saveAttachments(job captureJob, directory string) error {
	data, err := os.ReadFile(filepath.Join(directory, "manifest.json"))
	if err != nil {
		return err
	}
	var manifest []struct {
		Attachments []struct {
			ExportedFileName           string `json:"exportedFileName"`
			SuggestedHumanReadableName string `json:"suggestedHumanReadableName"`
		} `json:"attachments"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return fmt.Errorf("read attachment manifest: %w", err)
	}
	var failures []error
	for _, language := range job.languages {
		for _, screen := range screenNames {
			label := language.id + "__" + screen
			var files []string
			for _, test := range manifest {
				for _, attachment := range test.Attachments {
					name := attachment.SuggestedHumanReadableName
					if name == label || name == label+".png" || strings.HasPrefix(name, label+"_") {
						files = append(files, attachment.ExportedFileName)
					}
				}
			}
			if len(files) != 1 {
				failures = append(failures, fmt.Errorf("expected one %s attachment, found %d", label, len(files)))
				continue
			}
			if err = saveScreenshot(job.device, language, screen, filepath.Join(directory, files[0])); err != nil {
				failures = append(failures, fmt.Errorf("%s: %w", label, err))
			}
		}
	}
	return errors.Join(failures...)
}

func saveScreenshot(device captureDevice, language captureLanguage, screen, attachment string) error {
	data, err := os.ReadFile(attachment)
	if err != nil {
		return err
	}
	data, err = validatePNG(data, device, true)
	if err != nil {
		return err
	}
	for _, locale := range language.locales {
		if err = writeScreenshot(screenshotPath(device, locale, screen), data); err != nil {
			return err
		}
	}
	return nil
}

func remainingLanguages(device captureDevice, languages []captureLanguage) ([]captureLanguage, error) {
	var remaining []captureLanguage
	for _, language := range languages {
		complete := true
		for _, screen := range screenNames {
			var reusable []byte
			var missing []string
			for _, locale := range language.locales {
				path := screenshotPath(device, locale, screen)
				data, err := os.ReadFile(path)
				if err == nil {
					_, err = validatePNG(data, device, false)
				}
				if err != nil {
					missing = append(missing, path)
				} else if reusable == nil {
					reusable = data
				}
			}
			if reusable == nil {
				complete = false
				continue
			}
			for _, path := range missing {
				if err := writeScreenshot(path, reusable); err != nil {
					return nil, err
				}
			}
		}
		if !complete {
			remaining = append(remaining, language)
		}
	}
	return remaining, nil
}

func validatePNG(data []byte, device captureDevice, normalize bool) ([]byte, error) {
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if !slices.Contains(device.sizes, captureSize{width: config.Width, height: config.Height}) {
		return nil, fmt.Errorf("%dx%d is not an accepted screenshot size for %s", config.Width, config.Height, device.name)
	}
	decoded, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if !pngHasAlpha(data) {
		return data, nil
	}
	if !normalize {
		return nil, errors.New("PNG has alpha")
	}
	opaque := image.NewRGBA(decoded.Bounds())
	draw.Draw(opaque, opaque.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	draw.Draw(opaque, opaque.Bounds(), decoded, decoded.Bounds().Min, draw.Over)
	var output bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err = encoder.Encode(&output, opaque); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func pngHasAlpha(data []byte) bool {
	// Check the IHDR color type and the optional tRNS chunk after validating the PNG.
	if colorType := data[25]; colorType == 4 || colorType == 6 {
		return true
	}
	for chunks := data[8:]; len(chunks) >= 12; {
		length := int(binary.BigEndian.Uint32(chunks))
		switch string(chunks[4:8]) {
		case "tRNS":
			return true
		case "IDAT", "IEND":
			return false
		}
		chunks = chunks[12+length:]
	}
	return false
}

func screenshotPath(device captureDevice, locale, screen string) string {
	return filepath.Join(outputPath, locale, device.name, screen+".png")
}

func writeScreenshot(path string, data []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, ".screenshot-*.png")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	if err = errors.Join(writeErr, file.Chmod(0o644), file.Close()); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return os.Rename(file.Name(), path)
}
