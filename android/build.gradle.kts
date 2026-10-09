allprojects {
    repositories {
        // 网络受限环境的镜像链：dl.google.com = Google Maven 官方 CDN，
        // 阿里云镜像兜底；原始源保留在最后。
        maven("https://dl.google.com/dl/android/maven2")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 插件工程的 compileSdk 对齐。
//
// 背景：file_picker 8.3.7 在自身 build.gradle 里写死 compileSdk 34，而 Flutter 会为每个
// 插件注入 flutter_plugin_android_lifecycle（2.0.35 起其 AAR metadata 要求 compileSdk ≥ 36），
// 于是 :file_picker:checkDebugAarMetadata 直接失败。pubspec / pub 缓存都不是本项目该改的地方，
// 因此在 Gradle 层把所有 Android 子工程统一抬到 36（app 本来也是 36；插件只做编译期对齐，
// 不改 minSdk/targetSdk，不影响运行时行为）。
//
// 必须放在 afterEvaluate：Flutter 的 Gradle 插件也是在 afterEvaluate 里回写插件工程
// 的 compileSdk 的，只有排在它之后才不会被覆盖回去。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        try {
            when (androidExt) {
                is com.android.build.api.dsl.LibraryExtension -> androidExt.compileSdk = 36
                is com.android.build.api.dsl.ApplicationExtension -> androidExt.compileSdk = 36
                else -> Unit
            }
        } catch (t: Throwable) {
            logger.warn("gtd: cannot align compileSdk for ${project.path}: ${t.message}")
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
