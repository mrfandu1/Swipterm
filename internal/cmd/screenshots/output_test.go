package main

import (
	"bytes"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestResumePlansOnlyMissingScreens(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.MkdirAll(filepath.Dir(catalogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(catalogPath, []byte(`{"sourceLanguage":"en","strings":{"Setup":{"localizations":{"de":{}}}}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	sample := image.NewRGBA(image.Rect(0, 0, 640, 1136))
	draw.Draw(sample, sample.Bounds(), image.White, image.Point{}, draw.Src)
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, sample); err != nil {
		t.Fatal(err)
	}
	pngData := encoded.Bytes()
	write := func(locale, screen string, data []byte) {
		t.Helper()
		if err := writeScreenshot(filepath.Join("shots", locale, "iphone-4", screen+".png"), data); err != nil {
			t.Fatal(err)
		}
	}
	write("en-US", "01-Setup", pngData)
	write("en-GB", "01-Setup", []byte("interrupted write"))
	write("de-DE", "02-Terminal", pngData)
	jobs, err := planCapture("iphone-4", "en,de", "shots", true, false)
	if err != nil {
		t.Fatal(err)
	}
	want := []sceneBatch{
		{Screen: "setup", Attachment: "01-Setup", Languages: []string{"de"}},
		{Screen: "terminal", Attachment: "02-Terminal", Languages: []string{"en"}},
	}
	if len(jobs) != 1 || !reflect.DeepEqual(jobs[0].scenes, want) {
		t.Fatalf("unexpected capture jobs: %+v", jobs)
	}
	for _, locale := range outputLocales("en") {
		data, err := os.ReadFile(jobs[0].path(locale, "01-Setup"))
		if err != nil || !bytes.Equal(data, pngData) {
			t.Fatalf("failed to restore %s setup: %v", locale, err)
		}
	}

	// A previously interrupted export may have left two different complete images.
	sample.Set(0, 0, color.Black)
	var replacement bytes.Buffer
	if err := png.Encode(&replacement, sample); err != nil {
		t.Fatal(err)
	}
	write("en-GB", "01-Setup", replacement.Bytes())
	reused, err := jobs[0].reuseScreenshot("en", "01-Setup")
	if err != nil || reused {
		t.Fatalf("inconsistent regional aliases should be recaptured: reused=%t, error=%v", reused, err)
	}
}
