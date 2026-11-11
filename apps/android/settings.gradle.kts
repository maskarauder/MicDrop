pluginManagement {
  repositories {
    google()
    mavenCentral()
    gradlePluginPortal()
  }
}
dependencyResolutionManagement {
  repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
  repositories {
    google()
    mavenCentral()
  }
}
rootProject.name = "MicDrop"
// The security contract APK has no WebRTC dependency. Do not configure :app
// or require its fetched AAR for the isolated emulator run.
if (providers.gradleProperty("micdropPairingOnly").orNull != "true") include(":app")
include(":pairing-check")
