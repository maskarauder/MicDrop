package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/maskarauder/MicDrop/internal/identity"
)

func runIdentity(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || (args[0] != "init" && args[0] != "status") {
		fmt.Fprintln(stderr, "Usage: windows-host identity init | status [--state-dir <absolute directory>]")
		return 2
	}
	flags := flag.NewFlagSet("identity "+args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	directory := flags.String("state-dir", "", "absolute identity directory; defaults to this user's LocalAppData/MicDrop/identity")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 {
		return 2
	}
	var err error
	if *directory == "" {
		*directory, err = identity.DefaultDirectory()
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	store, err := identity.NewStore(*directory)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	var value *identity.Identity
	var created bool
	if args[0] == "init" {
		value, created, err = store.Ensure()
	} else {
		value, err = store.Load()
	}
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintln(stderr, "No host identity exists. Run windows-host identity init to create one.")
		return 1
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err = writeJSON(stdout, struct {
		identity.Info
		Created          bool `json:"created"`
		PairingAvailable bool `json:"pairing_available"`
	}{value.Info(), created, true}); err != nil {
		fmt.Fprintln(stderr, "Unable to write identity status")
		return 1
	}
	return 0
}
