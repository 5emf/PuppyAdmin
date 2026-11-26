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
        minSdk = 26
        targetSdk = 34
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "2.0." + (System.getenv("GITHUB_RUN_NUMBER") ?: "0")
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }   // Luau's native code generator: arm64 phones, x86_64 emulators
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_STL=c++_static") } }
    }

    // libpupemu: Luau VM + Puppy Admin's Game Boy / GBA modules, and doomgeneric (src/main/cpp)
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/emuAssets"))

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

// Puppy Admin's emulator modules and the free Cult-of-GBA BIOS go into the APK's assets/emu
val repoRoot: File = rootProject.projectDir.parentFile.parentFile
val copyEmuAssets = tasks.register<Copy>("copyEmuAssets") {
    from(repoRoot.resolve("emu")) { include("gameboy-*.lua"); rename { "gameboy.lua" } }
    from(repoRoot.resolve("emu")) { include("gba-*.lua"); rename { "gba.lua" } }
    from(repoRoot.resolve("assets/gba")) { include("cult_bios_v1.bin"); rename { "cult_bios.bin" } }
    into(layout.buildDirectory.dir("generated/emuAssets/emu"))
    doFirst {
        for (pattern in listOf("gameboy-", "gba-")) {
            val n = repoRoot.resolve("emu").listFiles()?.count { it.name.startsWith(pattern) && it.name.endsWith(".lua") } ?: 0
            check(n == 1) { "expected exactly one emu/$pattern*.lua, found $n" }
        }
    }
}
tasks.named("preBuild") { dependsOn(copyEmuAssets) }
