plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.macsecondmonitor.client"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.macsecondmonitor.client"
        // Android 8.0; HarmonyOS 2–4 devices run the Android app as-is.
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    // Release signing comes from the environment so no secrets live in the repository.
    signingConfigs {
        create("release") {
            val keystore = System.getenv("MSM_ANDROID_KEYSTORE")
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("MSM_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MSM_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("MSM_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (System.getenv("MSM_ANDROID_KEYSTORE") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    androidResources {
        generateLocaleConfig = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.preference)
    implementation(libs.material)

    testImplementation(libs.junit)
    // Android's org.json is a stub in local unit tests.
    testImplementation(libs.json)
}
