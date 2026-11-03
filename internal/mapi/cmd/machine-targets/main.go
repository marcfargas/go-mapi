// machine-targets records release facts and the final signed MSI's immutable bytes.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func main() {
	if err := run(os.Args[1:], time.Now().UTC()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(args []string, now time.Time) error {
	flags := flag.NewFlagSet("machine-targets", flag.ContinueOnError)
	specPath := flags.String("spec", "", "machine target spec JSON")
	msiPath := flags.String("msi", "", "final signed MSI")
	outPath := flags.String("out", "", "new plain target path")
	digestPath := flags.String("replay-digest-out", "", "optional new immutable replay digest path")
	artifactOrigin := flags.String("artifact-origin", update.MachineArtifactOrigin, "fixed HTTPS artifact release prefix")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *specPath == "" || *msiPath == "" || *outPath == "" {
		return errors.New("required: --spec --msi --out")
	}
	b, err := os.ReadFile(*specPath)
	if err != nil {
		return err
	}
	var spec update.MachineTargetSpec
	if err := update.DecodeJSON(b, &spec); err != nil {
		return err
	}
	f, err := os.Open(*msiPath)
	if err != nil {
		return err
	}
	defer f.Close()
	target, err := update.BuildMachineTargetForOrigin(spec, f, now, *artifactOrigin)
	if err != nil {
		return err
	}
	var digest string
	if *digestPath != "" {
		installed := make(map[string]string)
		for _, component := range spec.Contained {
			installed[component.Component] = component.Version
		}
		release, err := update.ParseTarget(spec.SKU, target, installed, now, *artifactOrigin)
		if err != nil {
			return err
		}
		digest = release.Digest()
	}
	if err := writeNew(*outPath, target); err != nil {
		return err
	}
	if *digestPath != "" {
		return writeNew(*digestPath, []byte(digest))
	}
	return nil
}

func writeNew(path string, content []byte) error {
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	if _, err := out.Write(content); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
