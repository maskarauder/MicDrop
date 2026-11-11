import java.util.Properties

plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
}

val releaseIdentity = Properties().apply {
  rootProject.file("../../internal/version/version.properties").inputStream().use { load(it) }
}
val micdropVersion = requireNotNull(releaseIdentity.getProperty("version"))
val micdropVersionCode = requireNotNull(releaseIdentity.getProperty("android_version_code")).toInt()
require(micdropVersionCode in 1..2100000000)

android {
  namespace = "com.maskarauder.micdrop"
  compileSdk = 36
  buildToolsVersion = "35.0.0"
  ndkVersion = "27.0.12077973"
  buildFeatures { buildConfig = true }

  defaultConfig {
    applicationId = "com.maskarauder.micdrop"
    minSdk = 31
    targetSdk = 36
    versionCode = micdropVersionCode
    versionName = micdropVersion
    val revision = System.getenv("GITHUB_SHA")?.takeIf { it.matches(Regex("[0-9a-f]{40}")) }?.take(12) ?: "local"
    buildConfigField("String", "REVISION", "\"$revision\"")
    ndk { abiFilters += "arm64-v8a" }
  }
  signingConfigs.getByName("debug") {
    System.getenv("MICDROP_DEBUG_KEYSTORE")?.let { path ->
      val keystore = file(path)
      require(keystore.isFile) { "MICDROP_DEBUG_KEYSTORE must point to an existing keystore" }
      storeFile = keystore
      storePassword = "android"
      keyAlias = "androiddebugkey"
      keyPassword = "android"
    }
  }
  buildTypes {
    debug { applicationIdSuffix = ".dev" }
    release { isMinifyEnabled = false }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
  sourceSets.getByName("main").assets.srcDir("../../../.deps/webrtc/android/assets")
  sourceSets.getByName("main").assets.srcDir("../../../third_party/qr-assets")
  sourceSets.getByName("main").assets.srcDir("../../../third_party/remote-assets")
  sourceSets.getByName("test").resources.srcDir("../../../internal/identity/testdata")
  sourceSets.getByName("test").resources.srcDir("../../../apps/windows-host/testdata")
}

val projectLicenseAssets = layout.buildDirectory.dir("generated/project-license-assets")
val syncProjectLicenses by tasks.registering(Sync::class) {
  from(rootProject.file("../../LICENSE"), rootProject.file("../../NOTICE"))
  into(projectLicenseAssets)
}
android.sourceSets.getByName("main").assets.srcDir(projectLicenseAssets)
tasks.named("preBuild") { dependsOn(syncProjectLicenses) }

dependencies {
  implementation("org.java-websocket:Java-WebSocket:1.6.0")
  implementation("org.slf4j:slf4j-nop:2.0.6")
  implementation("androidx.activity:activity:1.11.0")
  // Bundled decoder and camera UI: scanning also works without internet/GMS.
  implementation("com.journeyapps:zxing-android-embedded:4.3.0")
  implementation("com.google.zxing:core:3.5.4")
  // Session/UI lifecycle only; the existing native WebRTC engine still owns PCM.
  implementation("androidx.media3:media3-session:1.11.1")
  implementation(files("../../../.deps/webrtc/android/libwebrtc.aar"))
  testImplementation("junit:junit:4.13.2")
}
