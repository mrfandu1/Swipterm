package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"log"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"howett.net/plist"
)

const (
	ipaPath          = "build/Swipterm.ipa"
	metadataPath     = "build/metadata.json"
	altStorePath     = "build/altstore"
	entitlementsPath = "Swipterm/Swipterm.entitlements"
)

type metadata struct {
	Version string      `json:"version"`
	Build   json.Number `json:"build"`
}

type source struct {
	Name       string `json:"name"`
	Identifier string `json:"identifier"`
	SourceURL  string `json:"sourceURL"`
	IconURL    string `json:"iconURL"`
	Website    string `json:"website"`
	Apps       []app  `json:"apps"`
	News       []any  `json:"news"`
}

type app struct {
	Name                 string       `json:"name"`
	BundleIdentifier     string       `json:"bundleIdentifier"`
	DeveloperName        string       `json:"developerName"`
	LocalizedDescription string       `json:"localizedDescription"`
	IconURL              string       `json:"iconURL"`
	Category             string       `json:"category"`
	Versions             []appVersion `json:"versions"`
	AppPermissions       permissions  `json:"appPermissions"`
}

type appVersion struct {
	Version      string `json:"version"`
	BuildVersion string `json:"buildVersion"`
	Date         string `json:"date"`
	DownloadURL  string `json:"downloadURL"`
	Size         int64  `json:"size"`
	SHA256       string `json:"sha256"`
	MinOSVersion string `json:"minOSVersion"`
}

type permissions struct {
	Entitlements []string          `json:"entitlements"`
	Privacy      map[string]string `json:"privacy"`
}

var infoPlistName = regexp.MustCompile(`^Payload/[^/]+\.app/Info\.plist$`)

func writeMetadata() {
	info := readInfoPlist()
	content, err := json.Marshal(metadata{
		Version: info["CFBundleShortVersionString"].(string),
		Build:   json.Number(info["CFBundleVersion"].(string)),
	})
	if err != nil {
		log.Fatal(err)
	}
	err = os.WriteFile(metadataPath, append(content, '\n'), 0o644)
	if err != nil {
		log.Fatal(err)
	}
}

func buildAltStoreSource(arguments []string) {
	flags := flag.NewFlagSet("altstore", flag.ExitOnError)
	tag := flags.String("tag", "nightly", "release tag")
	flags.Parse(arguments)
	repository := os.Getenv("GITHUB_REPOSITORY")
	if repository == "" {
		repository = "swipt-automation/Swipterm"
	}
	websiteURL := "https://github.com/" + repository
	releaseURL := websiteURL + "/releases/download/" + *tag + "/"
	info := readInfoPlist()
	name := "Swipterm Nightly"
	identifier := info["CFBundleIdentifier"].(string)
	sourceURL := releaseURL + "altstore.json"
	if *tag != "nightly" {
		name = "Swipterm"
		identifier += ".stable"
		sourceURL = websiteURL + "/releases/latest/download/altstore.json"
	}
	content, err := os.ReadFile(ipaPath)
	if err != nil {
		log.Fatal(err)
	}
	hash := sha256.Sum256(content)
	entitlementsContent, err := os.ReadFile(entitlementsPath)
	if err != nil {
		log.Fatal(err)
	}
	var entitlements map[string]any
	_, err = plist.Unmarshal(entitlementsContent, &entitlements)
	if err != nil {
		log.Fatal(err)
	}
	privacy := make(map[string]string)
	for key, value := range info {
		description, isString := value.(string)
		if isString && strings.Contains(key, "UsageDescription") {
			privacy[key] = description
		}
	}
	appSource := source{
		Name:       name,
		Identifier: identifier,
		SourceURL:  sourceURL,
		IconURL:    releaseURL + "icon.png",
		Website:    websiteURL,
		Apps: []app{{
			Name:                 info["CFBundleDisplayName"].(string),
			BundleIdentifier:     info["CFBundleIdentifier"].(string),
			DeveloperName:        "nekohasekai",
			LocalizedDescription: "Swipterm runs a Linux distribution on this iPhone or iPad behind a Ghostty terminal.",
			IconURL:              releaseURL + "icon.png",
			Category:             "developer",
			Versions: []appVersion{{
				Version:      info["CFBundleShortVersionString"].(string),
				BuildVersion: info["CFBundleVersion"].(string),
				Date:         time.Now().UTC().Format(time.RFC3339),
				DownloadURL:  releaseURL + filepath.Base(ipaPath),
				Size:         int64(len(content)),
				SHA256:       hex.EncodeToString(hash[:]),
				MinOSVersion: info["MinimumOSVersion"].(string),
			}},
			AppPermissions: permissions{
				Entitlements: slices.Sorted(maps.Keys(entitlements)),
				Privacy:      privacy,
			},
		}},
		News: []any{},
	}
	output, err := json.MarshalIndent(appSource, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	err = os.MkdirAll(altStorePath, 0o755)
	if err != nil {
		log.Fatal(err)
	}
	err = os.WriteFile(filepath.Join(altStorePath, "altstore.json"), append(output, '\n'), 0o644)
	if err != nil {
		log.Fatal(err)
	}
}

func readInfoPlist() map[string]any {
	archive, err := zip.OpenReader(ipaPath)
	if err != nil {
		log.Fatal(err)
	}
	defer archive.Close()
	index := slices.IndexFunc(archive.File, func(file *zip.File) bool {
		return infoPlistName.MatchString(file.Name)
	})
	if index < 0 {
		log.Fatal("missing Info.plist in ", ipaPath)
	}
	reader, err := archive.File[index].Open()
	if err != nil {
		log.Fatal(err)
	}
	content, err := io.ReadAll(reader)
	reader.Close()
	if err != nil {
		log.Fatal(err)
	}
	var info map[string]any
	_, err = plist.Unmarshal(content, &info)
	if err != nil {
		log.Fatal(err)
	}
	return info
}
