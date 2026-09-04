plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// The marketing version is owned by the repo-root VERSION file, shared with the
// macOS side (scripts/check-version.sh enforces the macOS half). versionCode
// below stays a hand-bumped integer: Play requires a monotonic integer, and
// deriving one from a dotted string is how release trains break.
val marketingVersion = rootProject.file("../VERSION").readText().trim()

// Release signing comes from the environment, never from a file in this repo.
// The release workflow writes the keystore decoded from a GitHub secret and
// points EASYSHARE_KEYSTORE at it. When that variable is unset or the file is
// missing, no release signing config is created and `assembleRelease` produces
// an UNSIGNED apk, which Android cannot install — so the workflow publishes the
// debug-signed apk in that case instead. See docs/releasing.md.
val releaseKeystore = System.getenv("EASYSHARE_KEYSTORE")
    ?.takeIf { it.isNotBlank() }
    ?.let { file(it) }
    ?.takeIf { it.isFile }

android {
    namespace = "dev.easyshare.companion"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.easyshare.companion"
        minSdk = 29
        targetSdk = 35
        versionCode = 15
        versionName = marketingVersion
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("EASYSHARE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("EASYSHARE_KEY_ALIAS")
                keyPassword = System.getenv("EASYSHARE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Null when no keystore was supplied: an unsigned release build,
            // which is the signal the workflow falls back on.
            signingConfig = signingConfigs.findByName("release")
        }
    }

    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
