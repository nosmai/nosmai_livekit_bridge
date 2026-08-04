plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nosmai.nosmai_livekit_bridge_example"
    compileSdk = flutter.compileSdkVersion
    // Pinned rather than flutter.ndkVersion: that resolves to 28.2.13676358,
    // which is present in the SDK but CORRUPT (no source.properties), so
    // configuration fails with CXX1101 before anything compiles. 29.0.14206865
    // is a complete install and is what the Nosmai SDK itself is built with.
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Nosmai licence keys are bound to an application id — set this to the
        // id your key was issued for, and put the key in lib/main.dart.
        applicationId = "com.example.nosmai_livekit_bridge_example"
        // LiveKit/flutter_webrtc require API 24+; the plugin declares the same.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The camera SDK plugin declares this AAR compileOnly, which keeps the 36MB
    // binary out of the pub.dev package but means it is NOT packaged into the
    // app. The host has to add it as a real (runtime) dependency or the app
    // builds and then crashes on first native call with UnsatisfiedLinkError.
    implementation(files("libs/nosmai-release.aar"))
}
