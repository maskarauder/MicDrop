package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

type captureFunc func(context.Context, windowsaudio.Config) (windowsaudio.Report, []byte, error)

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func runCapture(ctx context.Context, args []string, stdout, stderr io.Writer, capture captureFunc) int {
	flags := flag.NewFlagSet("capture", flag.ContinueOnError)
	flags.SetOutput(stderr)
	id := flags.String("device", "", "output ID from devices; empty selects the default multimedia output once")
	duration := flags.Duration("duration", 5*time.Second, "wall duration from 100ms to 1m, in whole milliseconds")
	output := flags.String("output", "", "optional new PCM16 WAV file; otherwise retain no recording")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	config := windowsaudio.Config{EndpointID: *id, Duration: *duration, Record: *output != ""}
	if err := config.Validate(); err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "capture accepts flags only")
		return 2
	}
	var file *os.File
	if *output != "" {
		var err error
		file, err = os.OpenFile(*output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
	}
	keepFile := false
	defer func() {
		if file != nil {
			_ = file.Close()
			if !keepFile {
				_ = os.Remove(*output)
			}
		}
	}()
	// Only stderr carries progress; stdout can be redirected to a JSON report.
	fmt.Fprintf(stderr, "Capturing Windows output for %s. Press Ctrl+C to cancel.\n", *duration)
	report, pcm, err := capture(ctx, config)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	warnings := []string{}
	if report.Frames == 0 {
		warnings = append(warnings, "No packets arrived. Play audio on the selected output and retry; no WAV was saved.")
	} else {
		var peak float64
		for _, level := range report.Levels {
			peak = max(peak, level.Peak)
		}
		if peak == 0 {
			warnings = append(warnings, "Captured packets contain only silence; verify the selected output and source playback.")
		}
	}
	if report.Discontinuities > 0 || report.PositionGapFrames > 0 || report.PositionRegressions > 0 {
		warnings = append(warnings, "Capture has discontinuities or position gaps; WAV packets are concatenated without gap padding.")
	}
	if report.TimestampErrors > 0 {
		warnings = append(warnings, "Some packet timestamps were invalid and excluded from position calculations.")
	}
	if report.NonfiniteSamples > 0 || report.AboveFullScaleSamples > 0 {
		warnings = append(warnings, "Nonfinite samples become silence; WAV samples beyond full scale are clipped to PCM16 range.")
	}
	wavPath := ""
	if file != nil && report.Frames > 0 {
		if err := writeCaptureWAV(file, report.Format, report.Frames, pcm); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if err := file.Close(); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		keepFile = true
		wavPath = *output
	}
	if err := writeJSON(stdout, struct {
		windowsaudio.Report
		WAV      string   `json:"wav_file,omitempty"`
		Warnings []string `json:"warnings"`
	}{report, wavPath, warnings}); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if report.Frames == 0 {
		return 1
	}
	return 0
}

// WAVEFORMATEXTENSIBLE preserves channel layout, including multichannel output.
// No resampling or downmixing is performed. PCM was converted natively to PCM16.
func writeCaptureWAV(w io.Writer, format windowsaudio.Format, frames uint64, pcm []byte) error {
	if format.SampleRate < 8000 || format.SampleRate > 384000 || format.Channels == 0 || format.Channels > 32 ||
		len(pcm) > 64*1024*1024 || len(pcm)%(int(format.Channels)*2) != 0 ||
		uint64(len(pcm))/(uint64(format.Channels)*2) != frames {
		return errors.New("invalid captured PCM length or format")
	}
	header := make([]byte, 68)
	copy(header, "RIFF")
	binary.LittleEndian.PutUint32(header[4:], uint32(60+len(pcm)))
	copy(header[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(header[16:], 40)
	binary.LittleEndian.PutUint16(header[20:], 0xfffe) // WAVE_FORMAT_EXTENSIBLE
	binary.LittleEndian.PutUint16(header[22:], uint16(format.Channels))
	binary.LittleEndian.PutUint32(header[24:], format.SampleRate)
	binary.LittleEndian.PutUint32(header[28:], format.SampleRate*format.Channels*2)
	binary.LittleEndian.PutUint16(header[32:], uint16(format.Channels*2))
	binary.LittleEndian.PutUint16(header[34:], 16)
	binary.LittleEndian.PutUint16(header[36:], 22) // extension size
	binary.LittleEndian.PutUint16(header[38:], 16) // valid bits
	binary.LittleEndian.PutUint32(header[40:], format.ChannelMask)
	copy(header[44:], []byte{1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}) // PCM GUID
	copy(header[60:], "data")
	binary.LittleEndian.PutUint32(header[64:], uint32(len(pcm)))
	if err := writeAll(w, header); err != nil {
		return err
	}
	return writeAll(w, pcm)
}
