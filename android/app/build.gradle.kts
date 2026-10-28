import java.io.ByteArrayInputStream
import java.io.File
import java.util.Base64
import java.awt.image.BufferedImage
import javax.imageio.ImageIO


plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val generateLauncherIcons by tasks.registering {
    val iconSource = rootProject.file("../assets/images/app_launcher_icon.jpg.b64")
    inputs.file(iconSource)
    doLast {
        val encoded = iconSource.readText().trim()
        val bytes = Base64.getDecoder().decode(encoded)
        val source = ImageIO.read(ByteArrayInputStream(bytes))
            ?: error("Could not decode the supplied launcher icon")
        val densities = mapOf(
            "mipmap-ldpi" to 36,
            "mipmap-mdpi" to 48,
            "mipmap-hdpi" to 72,
            "mipmap-xhdpi" to 96,
            "mipmap-xxhdpi" to 144,
            "mipmap-xxxhdpi" to 192
        )
        val foregroundSizes = mapOf(
            "mipmap-ldpi" to 81,
            "mipmap-mdpi" to 108,
            "mipmap-hdpi" to 162,
            "mipmap-xhdpi" to 216,
            "mipmap-xxhdpi" to 324,
            "mipmap-xxxhdpi" to 432
        )
        fun writeIcon(size: Int, output: File) {
            output.parentFile.mkdirs()
            val scaled = BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB)
            val graphics = scaled.createGraphics()
            graphics.setRenderingHint(
                java.awt.RenderingHints.KEY_INTERPOLATION,
                java.awt.RenderingHints.VALUE_INTERPOLATION_BICUBIC
            )
            graphics.drawImage(source, 0, 0, size, size, null)
            graphics.dispose()
            check(ImageIO.write(scaled, "png", output)) { "Could not write ${output.path}" }
        }
        densities.forEach { (folder, size) ->
            writeIcon(size, file("src/main/res/$folder/ic_launcher.png"))
        }
        foregroundSizes.forEach { (folder, size) ->
            writeIcon(size, file("src/main/res/$folder/ic_launcher_foreground.png"))
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(generateLauncherIcons)
}

tasks.configureEach {
    if (name.startsWith("process") && name.endsWith("Resources")) {
        dependsOn(generateLauncherIcons)
    }
}


android {
    namespace = "com.saqia.saqia_station"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.saqia.saqia_station"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
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

flutter {
    source = "../.."
}
