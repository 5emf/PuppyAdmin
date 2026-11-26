plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing from the environment (GitHub secrets in .github/workflows/pupdates-android.yml).
// Without them only the debug APK is built.
val keystoreFile = System.getenv("PUPDATES_KEYSTORE_FILE")?.takeIf { it.isNotBlank() && file(it).exists() }

android {
    namespace = "com.pupdates.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.pupdates.app"
        minSdk = 24
        targetSdk = 34
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "2.0." + (System.getenv("GITHUB_RUN_NUMBER") ?: "0")
    }

    signingConfigs {
        if (keystoreFile != null) {
            create("release") {
                storeFile = file(keystoreFile)
                storePassword = System.getenv("PUPDATES_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("PUPDATES_KEY_ALIAS")
                keyPassword = System.getenv("PUPDATES_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystoreFile != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
