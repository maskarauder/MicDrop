#ifndef MICDROP_RTC_AUDIO_MODE_H
#define MICDROP_RTC_AUDIO_MODE_H
namespace micdrop {
// Sources 0..4 retain their original ABI meanings. Duplex is configured with
// separate capture and render IDs; the headless source exists only for contracts.
inline bool DesktopSource(int source) { return source < 2 || source >= 5; }
inline bool MicrophoneReturn(int source) { return source == 3 || source >= 5; }
inline bool CableOutput(int source) { return source == 3 || source == 5 || source == 6; }
inline bool LoopbackCapture(int source) { return source == 0 || source == 5; }
}
#endif
