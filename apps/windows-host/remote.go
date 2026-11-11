package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/maskarauder/MicDrop/internal/identity"
	"github.com/maskarauder/MicDrop/internal/rendezvous"
	"io"
	"os"
)

func remoteStore(directory string) (*identity.Store, error) {
	var err error
	if directory == "" {
		directory, err = identity.DefaultDirectory()
	}
	if err != nil {
		return nil, err
	}
	return identity.NewStore(directory)
}
func loadRemote(directory string) (rendezvous.RemoteConfig, error) {
	s, err := remoteStore(directory)
	if err != nil {
		return rendezvous.RemoteConfig{}, err
	}
	b, err := s.LoadRemote()
	if err != nil {
		return rendezvous.RemoteConfig{}, err
	}
	defer clear(b)
	return rendezvous.DecodeRemote(bytes.NewReader(b))
}
func runRemote(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || (args[0] != "import" && args[0] != "status" && args[0] != "forget") {
		fmt.Fprintln(stderr, "Usage: remote import --config <private JSON> [--state-dir <absolute path>] | remote status | remote forget")
		return 2
	}
	f := flag.NewFlagSet("remote", flag.ContinueOnError)
	f.SetOutput(stderr)
	directory := f.String("state-dir", "", "absolute protected identity directory")
	path := f.String("config", "", "private Windows remote configuration JSON")
	if f.Parse(args[1:]) != nil || f.NArg() != 0 || (args[0] == "import") != (*path != "") {
		return 2
	}
	s, err := remoteStore(*directory)
	if err != nil {
		fmt.Fprintln(stderr, "Cannot open Windows protected state.")
		return 1
	}
	if args[0] == "status" {
		c, err := loadRemote(*directory)
		if err != nil {
			fmt.Fprintln(stderr, "Remote configuration unavailable; import a configuration first.")
			return 1
		}
		fmt.Fprintf(stdout, "Remote endpoint: %s\nForce TURN relay: %t\n", c.URL, c.ForceRelay)
		return 0
	}
	var c rendezvous.RemoteConfig
	if args[0] == "import" {
		file, e := os.Open(*path)
		if e != nil {
			fmt.Fprintln(stderr, "Cannot open configuration file.")
			return 1
		}
		c, err = rendezvous.DecodeRemote(file)
		file.Close()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
	}
	if _, _, err = s.Ensure(); err != nil {
		fmt.Fprintln(stderr, "Cannot open protected host identity.")
		return 1
	}
	lock, err := s.OpenPairing()
	if err != nil {
		fmt.Fprintln(stderr, "Stop the Windows listener before changing remote settings.")
		return 1
	}
	defer lock.Close()
	if args[0] == "forget" {
		err = s.ForgetRemote()
	} else {
		b, _ := json.Marshal(c)
		defer clear(b)
		err = s.SaveRemote(b)
	}
	if err != nil {
		fmt.Fprintln(stderr, "Cannot save protected remote settings.")
		return 1
	}
	fmt.Fprintln(stdout, "Remote settings updated. Paired devices are unchanged.")
	return 0
}
