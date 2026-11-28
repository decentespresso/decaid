import java.nio.file.Paths
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.firebase-perf")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    signingConfigs {
            create("release") {
                storeFile = file("debug.keystore")
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "android"
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "androiddebugkey"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "android"
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

dependencies {
    testImplementation("junit:junit:4.13.2")
}

val guardGeneratedPluginRegistration = tasks.register("guardGeneratedPluginRegistration") {
    group = "verification"
    description =
        "Makes a failing plugin in Flutter's generated Android registrant fail admission " +
            "instead of being logged and skipped. Runs before every Kotlin and Java compile."
    outputs.upToDateWhen { false }
    doLast {
        val properties = Properties()
        rootProject.file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdk =
            properties.getProperty("flutter.sdk")
                ?: throw GradleException("flutter.sdk is missing from android/local.properties")
        val pluginBlocks =
            net.tadel.reaprime.gradle.GuardedPluginRegistration.guard(
                file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java").toPath(),
                Paths.get(flutterSdk),
            )
        logger.lifecycle(
            "guarded plugin registration: $pluginBlocks generated plugin registrations now " +
                "report failure",
        )
    }
}

tasks.configureEach {
    if (name.startsWith("compile") && (name.endsWith("JavaWithJavac") || name.endsWith("Kotlin"))) {
        dependsOn(guardGeneratedPluginRegistration)
    }
}




