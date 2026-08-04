allprojects {
    repositories {
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
// Force every Android subproject onto a working NDK.
//
// Pinning ndkVersion in app/build.gradle.kts is NOT enough: transitive plugin
// projects declare `ndkVersion flutter.ndkVersion` in their own build files.
// Here that is the `jni` package (pulled in via livekit_client), which resolves
// to 28.2.13676358 — present in the SDK but CORRUPT (an empty directory with no
// source.properties), so configuring :jni fails with CXX1101 before anything
// compiles. 29.0.14206865 is a complete install and is what the Nosmai SDK
// itself is built with.
//
// This MUST share the same subprojects{} block as evaluationDependsOn(":app"):
// that call evaluates the project immediately, so a later, separate
// afterEvaluate{} on the same project throws "Cannot run
// Project.afterEvaluate(Action) when the project is already evaluated."
// Registering the hook BEFORE evaluationDependsOn keeps it valid.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val setter = ext.javaClass.methods.firstOrNull {
                it.name == "setNdkVersion" && it.parameterTypes.size == 1
            }
            setter?.invoke(ext, "29.0.14206865")
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
