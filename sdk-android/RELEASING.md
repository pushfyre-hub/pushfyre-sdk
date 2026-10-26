# Releasing the Android SDK

Apps add the SDK with one line and nothing else, because Maven Central is already a default repository in every Android project:

```kotlin
implementation("io.github.pushfyre-hub:sdk-android:1.0.0")
```

That only works once a version is published to **Maven Central**. This is the one-time setup, then the routine release.

## One-time setup

1. **Central Portal account.** Sign up at <https://central.sonatype.com> with the publisher's account.
2. **Verify the namespace `io.github.pushfyre-hub`.** In the portal go to *Namespaces* → *Add Namespace* and enter `io.github.pushfyre-hub`. The portal shows a verification key. In the `pushfyre-hub` GitHub account create a **public** repository named exactly that key, click *Verify Namespace*, then delete the repository. (No DNS needed. A reverse-domain name such as `com.wonindia` would instead need a DNS `TXT` record on the company's domain.)
3. **Create a publishing token.** *Account* → *Generate User Token*. It gives a username and password for uploads (not your login).
4. **Create a signing key.** Central requires every file to be signed:
   ```bash
   gpg --gen-key
   gpg --keyserver keyserver.ubuntu.com --send-keys <KEY_ID>
   gpg --armor --export-secret-keys <KEY_ID>   # the SIGNING_KEY value below
   ```
5. **Add four GitHub repository secrets** (repo → *Settings* → *Secrets and variables* → *Actions*):

   | Secret | Value |
   |---|---|
   | `MAVEN_CENTRAL_USERNAME` | token username from step 3 |
   | `MAVEN_CENTRAL_PASSWORD` | token password from step 3 |
   | `SIGNING_KEY` | the armored private key from step 4 |
   | `SIGNING_KEY_PASSWORD` | the key's passphrase |

6. The repository root needs `settings.gradle.kts`, `gradle/`, `gradlew` and `.github/workflows/release-android-sdk.yml` next to `sdk-android/`, because the workflow runs `./gradlew :sdk-android:...` from the root.
7. **License.** The POM declares Apache 2.0 (Central requires a license). If the company wants a different one, change it in `sdk-android/build.gradle.kts` and add the matching `LICENSE` file to the repository.

## Each release

```bash
git tag 1.0.1
git push origin 1.0.1
```

The workflow builds, signs and publishes that version. It appears on Maven Central within a few minutes to an hour, and cannot be changed or removed afterwards, so test first with a snapshot:

```bash
./gradlew :sdk-android:publishToMavenLocal   # publishes 1.0.0-SNAPSHOT to your machine
```

To use it in an app on the same machine, add `mavenLocal()` to that app's repositories while testing.

## Internal GitLab registry

GitLab CI still publishes tagged builds to the private package registry, using `CI_JOB_TOKEN`, for internal projects.
