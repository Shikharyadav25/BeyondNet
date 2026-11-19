plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Robolectric 4.16.1 uses API 29 and 34 for the test cases and API 36 for
// compile-time resources. Resolve each version separately to retain all three.
val robolectricFrameworks = listOf(
    "10-robolectric-5803371-i7",
    "14-robolectric-10818077-i7",
    "16-robolectric-13921718-i7",
).map { version ->
    configurations.detachedConfiguration(
        dependencies.create("org.robolectric:android-all-instrumented:$version"),
    ).apply { isTransitive = false }
}
val robolectricFrameworkDir = layout.buildDirectory.dir("robolectric-frameworks")
val prepareRobolectricFrameworks = tasks.register<Sync>("prepareRobolectricFrameworks") {
    from(robolectricFrameworks)
    into(robolectricFrameworkDir)
}

android {
    namespace = "com.offlinekaro.offline_karo"
    // Compilation SDK is separate from the oldest supported phone version.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.offlinekaro.offline_karo"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // The distributed demo APK intentionally retains its development key
            // so existing enrolled installations can be upgraded in place.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            it.dependsOn(prepareRobolectricFrameworks)
            it.inputs.dir(robolectricFrameworkDir)
            it.systemProperty(
                "robolectric.dependency.dir",
                robolectricFrameworkDir.get().asFile.absolutePath,
            )
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}

// Flutter's asset-copy task and AGP's JVM test APK share the asset directory.
// Declare ordering explicitly for Gradle 9's task dependency validation.
tasks.matching { it.name == "packageDebugUnitTestForUnitTest" }.configureEach {
    dependsOn("copyFlutterAssetsDebug")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
