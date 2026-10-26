plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}

android {
    namespace = "com.wonindia.push"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    publishing { singleVariant("release") { withSourcesJar() } }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("androidx.core:core-ktx:1.15.0")
    // Exposed on the public API (requestNotificationPermission takes a ComponentActivity).
    api("androidx.activity:activity-ktx:1.9.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.wonindia.push"
            artifactId = "sdk-android"
            // CI_COMMIT_TAG is set automatically by GitLab CI when a pipeline runs off a
            // pushed tag (e.g. "1.0.1") - that becomes the real, immutable published
            // version. Locally, with no tag/CI, this falls back to the existing SNAPSHOT
            // so `publishToMavenLocal` keeps working exactly as it does today - a fixed
            // version is cached by consumers, which silently compiles them against a stale
            // copy of the SDK.
            version = System.getenv("CI_COMMIT_TAG") ?: "1.0.0-SNAPSHOT"
            afterEvaluate { from(components["release"]) }
        }
    }
    repositories {
        // Only resolvable inside a GitLab CI pipeline: CI_JOB_TOKEN is minted per-run and
        // scoped to this project, so publishing needs no manually-created/rotated secret.
        // Consumers still need their own read-only Deploy Token - see the settings.gradle.kts
        // snippet in the SDK README.
        maven {
            name = "gitlab"
            url = uri("${System.getenv("CI_API_V4_URL") ?: "https://gitlab01.daicompanies.com/api/v4"}/projects/${System.getenv("CI_PROJECT_ID")}/packages/maven")
            credentials(HttpHeaderCredentials::class) {
                name = "Job-Token"
                value = System.getenv("CI_JOB_TOKEN")
            }
            authentication { create<HttpHeaderAuthentication>("header") }
        }
    }
}
