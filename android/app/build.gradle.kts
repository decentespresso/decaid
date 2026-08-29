import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services") apply false
    id("com.google.firebase.firebase-perf") apply false
    id("com.google.firebase.crashlytics") apply false
    // END: FlutterFire Configuration
    // id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val personalBuild = System.getenv("PERSONAL_BUILD")
    ?.equals("true", ignoreCase = true) == true
val personalTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("Personal", ignoreCase = true)
}

if (personalTaskRequested && !personalBuild) {
    throw GradleException("Personal variants require PERSONAL_BUILD=true")
}

if (!personalBuild) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.firebase-perf")
    apply(plugin = "com.google.firebase.crashlytics")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (personalBuild) {
    if (!keystorePropertiesFile.isFile) {
        throw GradleException("Personal builds require android/key.properties")
    }
    keystorePropertiesFile.inputStream().use(keystoreProperties::load)
}

android {
    namespace = "net.tadel.reaprime"
    compileSdk = 36
    // ndkVersion = flutter.ndkVersion
		ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "net.tadel.reaprime"
        manifestPlaceholders["appLabel"] = "Decaid"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 35
        // Use git commit count as versionCode so debug and release builds always
        // share the same monotonically increasing version, preventing downgrade uninstalls.
        versionCode = providers.exec {
            commandLine("git", "rev-list", "--count", "origin/main")
        }.standardOutput.asText.get().trim().toInt()
        versionName = flutter.versionName
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("personal") {
            dimension = "distribution"
            applicationId = "io.github.rickono12.decaid"
            manifestPlaceholders["appLabel"] = "Decaid Fork"
        }
    }

    signingConfigs {
            create("release") {
                if (personalBuild) {
                    storeFile = file(
                        requireNotNull(keystoreProperties.getProperty("storeFile"))
                    )
                    storePassword = requireNotNull(
                        keystoreProperties.getProperty("storePassword")
                    )
                    keyAlias = requireNotNull(
                        keystoreProperties.getProperty("keyAlias")
                    )
                    keyPassword = requireNotNull(
                        keystoreProperties.getProperty("keyPassword")
                    )
                } else {
                    storeFile = file("debug.keystore")
                    storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "android"
                    keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "androiddebugkey"
                    keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "android"
                }
            }
            getByName("debug") {
                storeFile = file("debug.keystore")
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
        getByName("debug") {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}



