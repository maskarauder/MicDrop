//go:build !windows && !darwin && !linux

package identity

func protectionLabel() string                      { return "unsupported" }
func userDataRoot() (string, error)                { return "", ErrUnsupported }
func platformProtector() (protector, error)        { return nil, ErrUnsupported }
func platformPairingProtector() (protector, error) { return nil, ErrUnsupported }
func platformRemoteProtector() (protector, error)  { return nil, ErrUnsupported }
