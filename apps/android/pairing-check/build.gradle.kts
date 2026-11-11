plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
}

// Exercise the actual app's security code on an x86_64 Android emulator without
// packaging the arm64-only WebRTC engine. This APK is test-only, never shipped.
val syncPairingSources by tasks.registering(Sync::class) {
  from("../app/src/main/java") {
    include(listOf("AndroidIdentity", "PublicIdentity", "LanInvitation", "LanNetwork", "LanRecovery", "PairingClient", "ConnectionFailure", "ConnectionPreferences", "SignalingFailure", "SignalingRoute", "LocalProbe", "RemoteConnection", "RemoteHttp", "RemoteTunnel", "EngineStream", "OfferAttempt", "SessionResume", "PhoneControl", "TrickleIce", "ContinuousIce", "TurnTlsTrust")
      .map { "com/maskarauder/micdrop/$it.kt" })
  }
  into(layout.buildDirectory.dir("generated/pairing"))
}

android {
  namespace = "com.maskarauder.micdrop.pairingcheck"
  compileSdk = 36
  buildToolsVersion = "35.0.0"
  defaultConfig {
    applicationId = "com.maskarauder.micdrop.pairingcheck"
    minSdk = 31
    targetSdk = 36
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
  sourceSets.getByName("main").java.srcDir(layout.buildDirectory.dir("generated/pairing"))
}
tasks.named("preBuild") { dependsOn(syncPairingSources) }

dependencies {
  implementation("org.java-websocket:Java-WebSocket:1.6.0")
  implementation("org.slf4j:slf4j-nop:2.0.6")
  androidTestImplementation("androidx.test.ext:junit:1.3.0")
  androidTestImplementation("androidx.test:runner:1.7.0")
}
