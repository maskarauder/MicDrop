package main

import (
	"encoding/binary"
	"io"
	"math"
	"os"
	"time"

	"github.com/maskarauder/MicDrop/native/media"
)

func createToneFile(path string, duration time.Duration) (err error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		closeErr := f.Close()
		if err == nil {
			err = closeErr
		}
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	return writeToneWAV(f, int(duration*48000/time.Second))
}

// The command validates duration before calling this bounded offline writer.
func writeToneWAV(w io.Writer, frames int) error {
	tone, err := media.NewTone(media.ToneConfig{SampleRate: 48000, Channels: 2, Frequency: 440, Amplitude: 0.05})
	if err != nil {
		return err
	}
	defer tone.Close()
	header := make([]byte, 44)
	copy(header[0:], "RIFF")
	binary.LittleEndian.PutUint32(header[4:], uint32(36+frames*4))
	copy(header[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(header[16:], 16)
	binary.LittleEndian.PutUint16(header[20:], 1) // PCM
	binary.LittleEndian.PutUint16(header[22:], 2)
	binary.LittleEndian.PutUint32(header[24:], 48000)
	binary.LittleEndian.PutUint32(header[28:], 48000*4)
	binary.LittleEndian.PutUint16(header[32:], 4)
	binary.LittleEndian.PutUint16(header[34:], 16)
	copy(header[36:], "data")
	binary.LittleEndian.PutUint32(header[40:], uint32(frames*4))
	if err := writeAll(w, header); err != nil {
		return err
	}
	for frames > 0 {
		block := min(frames, 480)
		samples, err := tone.Render(block)
		if err != nil {
			return err
		}
		pcm := make([]byte, len(samples)*2)
		for i, sample := range samples {
			binary.LittleEndian.PutUint16(pcm[i*2:], uint16(int16(math.Round(float64(sample)*32767))))
		}
		if err := writeAll(w, pcm); err != nil {
			return err
		}
		frames -= block
	}
	return nil
}

func writeAll(w io.Writer, data []byte) error {
	n, err := w.Write(data)
	if err == nil && n != len(data) {
		return io.ErrShortWrite
	}
	return err
}
