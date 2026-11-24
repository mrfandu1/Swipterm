package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: ci version | metadata | altstore [-tag TAG] | next_project_version <marketing version> | publish_testflight <marketing version> <project version> [release notes]")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	switch os.Args[1] {
	case "version":
		calculateVersion(ctx)
	case "metadata":
		writeMetadata()
	case "altstore":
		buildAltStoreSource(os.Args[2:])
	case "next_project_version":
		if len(os.Args) < 3 {
			log.Fatal("usage: ci next_project_version <marketing version>")
		}
		printNextProjectVersion(ctx, os.Args[2])
	case "publish_testflight":
		if len(os.Args) < 4 {
			log.Fatal("usage: ci publish_testflight <marketing version> <project version> [release notes]")
		}
		publishTestflight(ctx, os.Args[2], os.Args[3], strings.Join(os.Args[4:], " "))
	default:
		log.Fatal("unknown command: ", os.Args[1])
	}
}
