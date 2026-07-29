import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads from android/key.properties, which is NOT committed
// to git (see .gitignore). Generate your upload keystore once with:
//   keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 \
//     -validity 10000 -alias upload
//
// then create android/key.properties (next to this file) with:
//
//   storePassword=<password you set above>
//   keyPassword=<password you set above>
//   keyAlias=upload
//   storeFile=</full/path/to/upload-keystore.jks>
//
// Keep upload-keystore.jks and key.properties out of git and back them up
// somewhere safe - losing them means you can never publish an update to
// this app under the same Play Store listing again.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.b4r34l.jwfusion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.b4r34l.jwfusion"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Uses the real upload key once android/key.properties exists;
            // falls back to the debug key so `flutter run --release` still
            // works before you've generated a keystore. A debug-signed
            // build will be REJECTED by Play Console - generate the
            // keystore above before uploading.
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
