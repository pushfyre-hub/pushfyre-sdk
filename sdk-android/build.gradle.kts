import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
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

}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("androidx.core:core-ktx:1.15.0")
    // Exposed on the public API (requestNotificationPermission takes a ComponentActivity).
    api("androidx.activity:activity-ktx:1.9.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

// Releases go to Maven Central, so an app only needs `implementation("io.github.pushfyre-hub:sdk-android:<version>")`
// with no extra repository or token. Publishing steps and the one-time Central setup: sdk-android/RELEASING.md.
//
// The version comes from the release tag (RELEASE_VERSION, or GitLab's CI_COMMIT_TAG). Locally, with no tag, it
// stays 1.0.0-SNAPSHOT so `publishToMavenLocal` keeps working for same-machine testing - a fixed version is cached
// by consumers, which silently compiles them against a stale copy of the SDK.
val sdkVersion = System.getenv("RELEASE_VERSION") ?: System.getenv("CI_COMMIT_TAG") ?: "1.0.0-SNAPSHOT"

mavenPublishing {
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL)
    // Central requires signed artifacts. The key is only present in the release job, so local builds are unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()

    coordinates("io.github.pushfyre-hub", "sdk-android", sdkVersion)

    pom {
        name.set("PushFyre Android SDK")
        description.set("Push notifications, in-app messages and user tagging for Android apps, backed by PushFyre.")
        inceptionYear.set("2026")
        url.set("https://github.com/pushfyre-hub/pushfyre-sdk")
        licenses {
            license {
                name.set("The Apache License, Version 2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("pushfyre")
                name.set("PushFyre")
                url.set("https://github.com/pushfyre-hub")
            }
        }
        scm {
            url.set("https://github.com/pushfyre-hub/pushfyre-sdk")
            connection.set("scm:git:https://github.com/pushfyre-hub/pushfyre-sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/pushfyre-hub/pushfyre-sdk.git")
        }
    }
}

// Internal GitLab registry, still published to from GitLab CI (CI_JOB_TOKEN is minted per run, nothing to rotate).
publishing {
    repositories {
        if (System.getenv("CI_PROJECT_ID") != null) {
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
}
