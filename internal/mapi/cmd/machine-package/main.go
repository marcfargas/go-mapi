package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func main() {
	flag.Parse()
	if flag.NArg() != 2 {
		fail("usage: machine-package SKU PACKAGE_RELEASE")
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(flag.Arg(0)), flag.Arg(1))
	if err != nil {
		fail(err.Error())
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(identity); err != nil {
		fail(err.Error())
	}
}

func fail(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
