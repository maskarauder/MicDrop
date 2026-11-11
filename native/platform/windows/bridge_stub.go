//go:build !windows

package windowsaudio

import "context"

func InputDevices() ([]Device, error) { return nil, ErrUnsupported }

func BridgeCheck(ctx context.Context, config BridgeConfig) (BridgeReport, error) {
	if err := config.Validate(); err != nil {
		return BridgeReport{}, err
	}
	if err := ctx.Err(); err != nil {
		return BridgeReport{}, err
	}
	return BridgeReport{}, ErrUnsupported
}
