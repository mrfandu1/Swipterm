package main

import (
	"log"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: ci version | metadata | altstore [-tag TAG]")
	}
	switch os.Args[1] {
	case "version":
		calculateVersion()
	case "metadata":
		writeMetadata()
	case "altstore":
		buildAltStoreSource(os.Args[2:])
	default:
		log.Fatal("unknown command: ", os.Args[1])
	}
}
