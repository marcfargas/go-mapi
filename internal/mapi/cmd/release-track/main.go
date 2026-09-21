package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func main() {
	githubOutput := flag.String("github-output", "", "append GitHub Actions outputs to this file")
	flag.Parse()
	if flag.NArg() != 1 {
		fail("usage: release-track [--github-output PATH] VERSION")
	}
	version := flag.Arg(0)
	track := mapi.ReleaseTrack(version)
	if track == "" || strings.HasPrefix(version, "3.0.") {
		fail("version does not belong to a new go-mapi release line: " + version)
	}
	promotion := strings.Split(version, "+")[0]
	if track == "development" {
		core := strings.Split(version, "-")[0]
		parts := strings.Split(core, ".")
		major, err := strconv.ParseUint(parts[0], 10, 64)
		if err != nil || major == ^uint64(0) {
			fail("version cannot be promoted: " + version)
		}
		promotion = fmt.Sprintf("%d.%s.%s", major+1, parts[1], parts[2])
	}
	lines := fmt.Sprintf("track=%s\npromotion_version=%s\n", track, promotion)
	fmt.Print(lines)
	if *githubOutput != "" {
		file, err := os.OpenFile(*githubOutput, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
		if err != nil {
			fail(err.Error())
		}
		if _, err := file.WriteString(lines); err != nil {
			file.Close()
			fail(err.Error())
		}
		if err := file.Close(); err != nil {
			fail(err.Error())
		}
	}
}

func fail(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
