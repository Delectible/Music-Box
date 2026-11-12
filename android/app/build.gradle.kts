plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dingo.roadie"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dingo.roadie"
        // Car head units commonly run Android 10 (29). 26+ for the tag library.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Phones and car head units (64- and 32-bit ARM), plus 64-bit emulators.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // yt-dlp runs Python from the native library folder: it must be unpacked.
    packaging { jniLibs { useLegacyPackaging = true } }

    // Release builds are signed with the private upload key when CI hands it
    // over (GitHub secrets ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD,
    // decoded to ROADIE_KEYSTORE by the workflow). Without it they use the
    // public test key, so every test build installs over the last one.
    val uploadKeystore = System.getenv("ROADIE_KEYSTORE")?.takeIf { it.isNotBlank() }
    signingConfigs {
        create("test") {
            storeFile = file("roadie-test.jks")
            storePassword = "roadie"
            keyAlias = "roadie"
            keyPassword = "roadie"
        }
        if (uploadKeystore != null) {
            create("upload") {
                storeFile = file(uploadKeystore)
                storePassword = System.getenv("ROADIE_KEYSTORE_PASSWORD")
                keyAlias = "upload"
                keyPassword = System.getenv("ROADIE_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (uploadKeystore != null) "upload" else "test")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Reading and writing tags and covers inside music files.
    implementation("net.jthink:jaudiotagger:3.0.1")
    // Hiding the system bars (full screen setting).
    implementation("androidx.core:core-ktx:1.13.1")
    // yt-dlp with Python and ffmpeg (SoundCloud and other sites), updated at runtime.
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    // Daily yt-dlp update check in the background.
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}

flutter {
    source = "../.."
}
