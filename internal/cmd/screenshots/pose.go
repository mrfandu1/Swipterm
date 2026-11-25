package main

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
)

func setSimulatorPose(ctx context.Context, udid, pose, directory string) error {
	helper, err := filepath.Abs(filepath.Join(directory, "hinge"))
	if err != nil {
		return err
	}
	command := exec.CommandContext(ctx, "xcrun", "--sdk", "iphonesimulator", "clang",
		"-fobjc-arc", "-mios-simulator-version-min=17.0", "-framework", "Foundation", "-framework", "IOKit",
		"internal/cmd/screenshots/hinge/main.m", "-o", helper,
	)
	if err := runCommand(command); err != nil {
		return fmt.Errorf("build simulator hinge helper: %w", err)
	}
	_, err = simulatorCommand(ctx, "spawn", udid, helper, pose)
	return err
}
