// machine-targets signs one final machine MSI's immutable release metadata.
// Its private key is read only from a protected PKCS#8 PEM file at runtime.
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
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
	rootPath := flags.String("root", "", "trusted machine root JSON path")
	specPath := flags.String("spec", "", "machine target specification JSON path")
	msiPath := flags.String("msi", "", "final signed MSI path")
	keyPath := flags.String("key-pem", "", "protected Ed25519 PKCS#8 PEM path")
	keyID := flags.String("key-id", "", "trusted target signer ID")
	outPath := flags.String("out", "", "new targets envelope path")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *rootPath == "" || *specPath == "" || *msiPath == "" || *keyPath == "" || *keyID == "" || *outPath == "" {
		return errors.New("required: --root --spec --msi --key-pem --key-id --out")
	}
	rootBytes, err := os.ReadFile(*rootPath)
	if err != nil {
		return fmt.Errorf("read trusted root: %w", err)
	}
	var root update.Root
	if err := update.DecodeJSON(rootBytes, &root); err != nil {
		return fmt.Errorf("decode trusted root: %w", err)
	}
	specBytes, err := os.ReadFile(*specPath)
	if err != nil {
		return fmt.Errorf("read target specification: %w", err)
	}
	var spec update.MachineTargetSpec
	if err := update.DecodeJSON(specBytes, &spec); err != nil {
		return fmt.Errorf("decode target specification: %w", err)
	}
	keyBytes, err := os.ReadFile(*keyPath)
	if err != nil {
		return errors.New("read protected signing key failed")
	}
	block, rest := pem.Decode(keyBytes)
	if block == nil || block.Type != "PRIVATE KEY" || len(rest) != 0 {
		return errors.New("invalid Ed25519 PKCS#8 signing key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return errors.New("invalid Ed25519 PKCS#8 signing key")
	}
	key, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return errors.New("signing key is not Ed25519")
	}
	msi, err := os.Open(*msiPath)
	if err != nil {
		return fmt.Errorf("open final MSI: %w", err)
	}
	defer msi.Close()
	envelope, err := update.SignMachineTargets(root, spec, msi, map[string]ed25519.PrivateKey{*keyID: key}, now)
	if err != nil {
		return err
	}
	output, err := os.OpenFile(*outPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("create new targets envelope: %w", err)
	}
	if _, err := output.Write(envelope); err != nil {
		output.Close()
		return fmt.Errorf("write targets envelope: %w", err)
	}
	if err := output.Sync(); err != nil {
		output.Close()
		return fmt.Errorf("sync targets envelope: %w", err)
	}
	if err := output.Close(); err != nil {
		return fmt.Errorf("close targets envelope: %w", err)
	}
	return nil
}
