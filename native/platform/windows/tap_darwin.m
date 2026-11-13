// SPDX-License-Identifier: MPL-2.0
//go:build darwin && arm64

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioHardwareTapping.h>
#include <CoreAudio/CATapDescription.h>
#include <CoreAudio/CoreAudio.h>
#include <Foundation/Foundation.h>

#if __has_feature(objc_arc)
#define MD_BRIDGE_CF(type, expr) (__bridge type)(expr)
#define MD_OBJC_RELEASE(expr) ((void)(expr))
#else
#define MD_BRIDGE_CF(type, expr) ((type)(expr))
#define MD_OBJC_RELEASE(expr) [(expr) release]
#endif

OSStatus micdrop_macos_create_tap_aggregate(
    const char* device_uid_utf8,
    AudioObjectID* out_tap,
    AudioObjectID* out_aggregate) {
  if (!device_uid_utf8 || !*device_uid_utf8 || !out_tap || !out_aggregate) {
    return kAudio_ParamError;
  }
  *out_tap = kAudioObjectUnknown;
  *out_aggregate = kAudioObjectUnknown;

  @autoreleasepool {
    if (@available(macOS 14.2, *)) {
      NSString* device_uid = [NSString stringWithUTF8String:device_uid_utf8];
      if (device_uid == nil) {
        return kAudio_ParamError;
      }

      CATapDescription* tap_desc =
          [[CATapDescription alloc] initWithProcesses:@[] andDeviceUID:device_uid withStream:0];
      if (tap_desc == nil) {
        return kAudioHardwareUnspecifiedError;
      }

      [tap_desc setMuteBehavior:CATapUnmuted];
      [tap_desc setPrivate:YES];
      [tap_desc setExclusive:YES];
      [tap_desc setName:@"MicDrop Loopback Tap"];

      AudioObjectID tap_id = kAudioObjectUnknown;
      OSStatus status = AudioHardwareCreateProcessTap(tap_desc, &tap_id);
      if (status != noErr) {
        MD_OBJC_RELEASE(tap_desc);
        return status;
      }

      NSString* tap_uid = [[tap_desc UUID] UUIDString];
      MD_OBJC_RELEASE(tap_desc);
      if (tap_uid == nil) {
        AudioHardwareDestroyProcessTap(tap_id);
        return kAudioHardwareUnspecifiedError;
      }

      NSString* agg_uid =
          [NSString stringWithFormat:@"io.micdrop.tap.%@", [[NSUUID UUID] UUIDString]];
      NSDictionary* agg_props = @{
        @kAudioAggregateDeviceNameKey : @"MicDrop Loopback Aggregate",
        @kAudioAggregateDeviceUIDKey : agg_uid,
        @kAudioAggregateDeviceTapListKey : @[ @{
          @kAudioSubTapUIDKey : tap_uid,
          @kAudioSubTapDriftCompensationKey : @YES,
        } ],
        @kAudioAggregateDeviceTapAutoStartKey : @YES,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
      };

      AudioObjectID aggregate_id = kAudioObjectUnknown;
      status = AudioHardwareCreateAggregateDevice(
          MD_BRIDGE_CF(CFDictionaryRef, agg_props), &aggregate_id);
      if (status != noErr) {
        AudioHardwareDestroyProcessTap(tap_id);
        return status;
      }

      *out_tap = tap_id;
      *out_aggregate = aggregate_id;
      return noErr;
    }
    return kAudioHardwareUnsupportedOperationError;
  }
}

void micdrop_macos_destroy_tap_aggregate(AudioObjectID tap_id, AudioObjectID aggregate_id) {
  @autoreleasepool {
    if (aggregate_id != kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregate_id);
    }
    if (@available(macOS 14.2, *)) {
      if (tap_id != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tap_id);
      }
    }
  }
}
