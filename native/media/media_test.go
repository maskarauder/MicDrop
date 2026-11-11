package media

import (
	"math"
	"testing"
)

func TestToneBoundaryAndLifetime(t *testing.T) {
	tone, err := NewTone(ToneConfig{48000, 2, 1000, 0.05})
	if err != nil {
		t.Fatal(err)
	}
	defer tone.Close()
	samples, err := tone.Render(48)
	if err != nil {
		t.Fatal(err)
	}
	if len(samples) != 96 || math.Abs(float64(samples[24])-0.05) > 1e-6 {
		t.Fatalf("unexpected native waveform: len=%d, quarter-cycle=%v", len(samples), samples[24])
	}
	for _, frames := range []int{-1, 0, MaxBlockFrames + 1} {
		if _, err := tone.Render(frames); err == nil {
			t.Fatalf("accepted frames=%d", frames)
		}
	}
	tone.Close()
	if _, err := tone.Render(1); err == nil {
		t.Fatal("rendered after close")
	}
}

func TestInvalidToneConfig(t *testing.T) {
	for _, c := range []ToneConfig{
		{-1, 2, 440, 0.05}, {48000, 0, 440, 0.05},
		{48000, 2, float32(math.NaN()), 0.05}, {48000, 2, 440, 2},
	} {
		if tone, err := NewTone(c); err == nil {
			tone.Close()
			t.Fatalf("accepted %+v", c)
		}
	}
}
