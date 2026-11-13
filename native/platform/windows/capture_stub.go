//go:build !(windows || (linux && amd64) || (darwin && arm64))

package windowsaudio

import "context"

func Available() bool { return false }

func Devices() ([]Device, error) { return nil, ErrUnsupported }

func Capture(ctx context.Context, config Config) (Report, []byte, error) {
	if err := config.Validate(); err != nil {
		return Report{}, nil, err
	}
	if err := ctx.Err(); err != nil {
		return Report{}, nil, err
	}
	return Report{}, nil, ErrUnsupported
}
