plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.wearlink.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.wearlink.app"
        // Wear OS 3+ = API 30. Health Services client requires API 30+.
        minSdk = 30
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Wear OS Health Services — passive + active health data collection.
    implementation("androidx.health:health-services-client:1.1.0-rc02")
    // Periodic background sync that respects Doze.
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    // Coroutines (used by platform channels + native collectors).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

flutter {
    source = "../.."
}