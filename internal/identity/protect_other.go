//go:build !windows

package identity

func platformProtector() (protector, error)        { return nil, ErrUnsupported }
func platformPairingProtector() (protector, error) { return nil, ErrUnsupported }
func platformRemoteProtector() (protector, error)  { return nil, ErrUnsupported }
