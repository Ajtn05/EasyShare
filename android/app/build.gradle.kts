plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// The release version is shared with the macOS app.
val marketingVersion = rootProject.file("../VERSION").readText().trim()

// Release signing is supplied by the CI environment.
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
