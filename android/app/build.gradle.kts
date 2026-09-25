plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "cz.drabek.chuvicka"
    compileSdk = 35

    defaultConfig {
        applicationId = "cz.drabek.chuvicka"
        minSdk = 26          // Android 8: an old phone can be the baby phone.
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    // The release key comes from CI secrets, so each new APK installs over the old one.
    // Without the secrets (a local build), the APK uses the debug key.
    signingConfigs {
        create("release") {
            val store = System.getenv("CHUVICKA_KEYSTORE")
            if (store != null) {
                storeFile = file(store)
                storeType = "pkcs12"
                storePassword = System.getenv("CHUVICKA_KEYSTORE_PASSWORD")
                keyAlias = "chuvicka"
                keyPassword = System.getenv("CHUVICKA_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (System.getenv("CHUVICKA_KEYSTORE") != null)
                signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")

    val camerax = "1.4.1"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")

    // The QR code of the pairing: make it on the phone at the baby, read it on the parent's.
    implementation("com.google.zxing:core:3.5.3")
}
