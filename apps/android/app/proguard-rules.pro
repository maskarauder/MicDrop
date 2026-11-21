# SPDX-License-Identifier: MPL-2.0
# R8 keep rules for MicDrop Android release builds.
# Keep rules are intentionally narrow so R8 can shrink, optimize, and obfuscate
# app and library bytecode while preserving JNI, reflection, and service contracts.

# Retain line numbers for Play Console / retrace crash deobfuscation without
# embedding local source file paths in release DEX metadata.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# WebRTC / JNI_Zero runtime entry points resolved by name from libjingle_peerconnection_so.so.
-keepclasseswithmembernames,includedescriptorclasses class J.N {
    native <methods>;
}
-keep class org.jni_zero.JniZero { *; }
-keep class org.webrtc.WebRtcClassLoader { *; }
-keep class org.webrtc.JniHelper { *; }
-keep class org.webrtc.JNILogging { *; }
# Pinned libwebrtc.aar omits optional native-log bridge LoggingJni; MicDrop never calls
# Logging.enableLogToDebugOutput(), so the Logging.log() branch referencing it is unreachable.
-dontwarn org.webrtc.LoggingJni

# Keep constructors, methods, and fields invoked from native WebRTC / JNI_Zero code,
# together with their parameter/return descriptor classes (including WebRTC enums).
# Separate blocks are required because -keepclasseswithmembers ANDs all listed members.
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.webrtc.CalledByNative <init>(...);
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.webrtc.CalledByNative <methods>;
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.webrtc.CalledByNativeUnchecked <init>(...);
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.webrtc.CalledByNativeUnchecked <methods>;
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.jni_zero.CalledByNative <init>(...);
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.jni_zero.CalledByNative <methods>;
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.jni_zero.CalledByNativeUnchecked <init>(...);
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.jni_zero.CalledByNativeUnchecked <methods>;
}
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.jni_zero.AccessedByNative <fields>;
}
-keepclasseswithmembers,includedescriptorclasses class org.jni_zero.** {
    @org.jni_zero.CalledByNative <init>(...);
}
-keepclasseswithmembers,includedescriptorclasses class org.jni_zero.** {
    @org.jni_zero.CalledByNative <methods>;
}
-keepclasseswithmembers,includedescriptorclasses class org.jni_zero.** {
    @org.jni_zero.CalledByNativeUnchecked <init>(...);
}
-keepclasseswithmembers,includedescriptorclasses class org.jni_zero.** {
    @org.jni_zero.CalledByNativeUnchecked <methods>;
}
-keepclasseswithmembers,includedescriptorclasses class org.jni_zero.** {
    @org.jni_zero.AccessedByNative <fields>;
}

# MicDrop reflectively reads these app-owned WebRTC audio fields in
# OutputRouting.kt (WebRtcOutputAccess) and MicrophoneInput.kt.
-keepclassmembers class org.webrtc.audio.JavaAudioDeviceModule {
    private final org.webrtc.audio.WebRtcAudioRecord audioInput;
    private final org.webrtc.audio.WebRtcAudioTrack audioOutput;
}
-keep class org.webrtc.audio.WebRtcAudioTrack {
    private android.media.AudioTrack audioTrack;
}
-keep class org.webrtc.audio.WebRtcAudioRecord {
    private android.media.AudioRecord audioRecord;
}

# SLF4J 2.x discovers NOPServiceProvider via META-INF/services for Java-WebSocket.
-keep class org.slf4j.nop.NOPServiceProvider {
    public <init>();
}

# Keep EdgeToEdge.enable entry point and its parameter types so Play Console's
# static edge-to-edge inspection recognizes the opt-in call in minified releases.
-keep,includedescriptorclasses class androidx.activity.EdgeToEdge {
    public static void enable(...);
}
