# Third-party licenses

This inventory covers the built-in video player dependency added to the Android
application. Versions are those selected by the Android release runtime
dependency graph.

| Component | Version | License | Purpose |
| --- | --- | --- | --- |
| AndroidX Media3 ExoPlayer | 1.9.2 | Apache-2.0 | Local video playback through Android's media framework |
| AndroidX Media3 Common | 1.9.2 | Apache-2.0 | Shared Media3 player APIs and data types |
| AndroidX Media3 Container | 1.9.2 | Apache-2.0 | Media container parsing |
| AndroidX Media3 Database | 1.9.2 | Apache-2.0 | Media3 database utilities |
| AndroidX Media3 DataSource | 1.9.2 | Apache-2.0 | Local-file data access |
| AndroidX Media3 Decoder | 1.9.2 | Apache-2.0 | Decoder interfaces and integration; does not bundle codecs |
| AndroidX Media3 Extractor | 1.9.2 | Apache-2.0 | Media container extraction |

## Built-in Archive Manager

The Android archive engine runs outside the UI thread. Published artifact sizes
below are the downloaded JAR sizes; the release APK delta will be measured
separately after a native build.

| Component | Version | License | Published JAR size | Purpose |
| --- | --- | --- | ---: | --- |
| Zip4j | 2.11.6 | Apache-2.0 | 213,881 bytes | ZIP listing, creation, extraction, and password-protected ZIP support |
| Apache Commons Compress | 1.28.0 | Apache-2.0 | 1,117,221 bytes | 7z, TAR, gzip, bzip2, and XZ container/compression support |
| XZ for Java | 1.12 | 0BSD | 168,792 bytes | XZ codec and 7z compression support |
| Junrar | 8.1.2 | UnRAR license | 247,983 bytes | RAR extraction only; never used to create RAR archives |

Runtime dependencies resolved by these libraries:

| Component | Version | License | Published JAR size | Required by |
| --- | --- | --- | ---: | --- |
| Commons Codec | 1.19.0 | Apache-2.0 | 374,716 bytes | Apache Commons Compress |
| Commons IO | 2.20.0 | Apache-2.0 | 563,971 bytes | Apache Commons Compress |
| Commons Lang | 3.18.0 | Apache-2.0 | 702,952 bytes | Apache Commons Compress |
| SLF4J API | 2.0.17 | MIT | 69,908 bytes | Junrar |

The archive dependency artifacts total approximately 3.0 MiB before Android
release shrinking. Junrar and SLF4J add approximately 311 KiB of JAR inputs.
The Android-provided `java.util.zip` APIs require no additional artifact.

### UnRAR license

Junrar carries the following license. It permits handling/extracting RAR files,
but prohibits use to recreate the proprietary RAR compression algorithm or to
develop a RAR-compatible archiver. Junrar is therefore used only for extraction.

```text
The source code of UnRAR utility is freeware. This means:

1. All copyrights to RAR and the utility UnRAR are exclusively owned by the
   author - Alexander Roshal.

2. The UnRAR sources may be used in any software to handle RAR archives without
   limitations free of charge, but cannot be used to re-create the RAR
   (WinRAR) compression algorithm, which is proprietary. Distribution of modified UnRAR
   sources in separate form or as a part of other software is permitted,
   provided that it is clearly stated in the documentation and source comments
   that the code may not be used to develop a RAR (WinRAR) compatible archiver.

3. The UnRAR utility may be freely distributed. It is allowed to distribute
   UnRAR inside of other software packages.

4. THE RAR ARCHIVER AND THE UnRAR UTILITY ARE DISTRIBUTED "AS IS". NO WARRANTY
   OF ANY KIND IS EXPRESSED OR IMPLIED. YOU USE AT YOUR OWN RISK. THE AUTHOR
   WILL NOT BE LIABLE FOR DATA LOSS, DAMAGES, LOSS OF PROFITS OR ANY OTHER KIND
   OF LOSS WHILE USING OR MISUSING THIS SOFTWARE.

5. Installing and using the UnRAR utility signifies acceptance of these terms
   and conditions of the license.

6. If you don't agree with terms of the license you must remove UnRAR files
   from your storage devices and cease to use the utility.

Alexander Roshal
```

The selected Media3 dependency branch also resolves these transitive
dependencies. Several AndroidX and Kotlin libraries are shared with existing
Flutter plugins; their presence in this table does not mean the player added a
second copy to the APK.

| Transitive component(s) | Selected version(s) | License | Purpose |
| --- | --- | --- | --- |
| AndroidX Annotation / Annotation JVM | 1.8.1 | Apache-2.0 | Android API annotations |
| AndroidX Annotation Experimental | 1.4.0 | Apache-2.0 | Experimental API annotations |
| AndroidX Collection | 1.2.0 | Apache-2.0 | Collection utilities |
| AndroidX Core | 1.13.1 | Apache-2.0 | Android platform compatibility utilities |
| AndroidX Concurrent Futures | 1.1.0 | Apache-2.0 | Future interoperability |
| AndroidX Interpolator | 1.0.0 | Apache-2.0 | Animation interpolation |
| AndroidX Lifecycle Runtime / Common | 2.7.0 | Apache-2.0 | Lifecycle support |
| AndroidX Arch Core Common / Runtime | 2.2.0 | Apache-2.0 | Lifecycle runtime support |
| AndroidX ExifInterface | 1.4.1 | Apache-2.0 | Media metadata support |
| AndroidX ProfileInstaller | 1.3.1 | Apache-2.0 | Runtime profile installation |
| AndroidX Startup Runtime | 1.1.1 | Apache-2.0 | AndroidX component initialization |
| AndroidX Tracing | 1.2.0 | Apache-2.0 | Platform tracing support |
| AndroidX VersionedParcelable | 1.1.1 | Apache-2.0 | Versioned parcel support |
| Google Guava (Android) | 33.3.1-android | Apache-2.0 | Shared Java utilities |
| Google FailureAccess | 1.0.2 | Apache-2.0 | Guava failure propagation |
| Google ListenableFuture compatibility artifact | 9999.0-empty-to-avoid-conflict-with-guava | Apache-2.0 | Guava dependency conflict placeholder |
| Kotlin Standard Library | 2.3.20 | Apache-2.0 | Kotlin runtime |
| Kotlin Standard Library JDK 7 / JDK 8 | 1.8.20 | Apache-2.0 | Kotlin JDK compatibility |
| kotlinx.coroutines Android / Core / Core JVM | 1.7.3 | Apache-2.0 | Coroutine runtime used by AndroidX |
| JetBrains Annotations | 23.0.0 | Apache-2.0 | Kotlin/JVM annotations |
| JSpecify | 1.0.0 | Apache-2.0 | Nullness annotations |

No Dart video-player package was added. The player does not bundle FFmpeg,
libVLC, libmpv, codecs, or software decoders; supported formats depend on the
Android version and device-provided media decoders. Versions above are from
Gradle's resolved `releaseRuntimeClasspath` dependency graph.

The full Apache License 2.0 text and Android Open Source Project attribution
for Media3 are registered in Flutter's license registry and available from the
in-app **Settings > About > Open source licenses** page.

## Whole-app dependency review

The `pubspec.lock` review covered all 89 resolved hosted Dart packages,
including development and transitive dependencies. Their cached package license
files identified them as MIT, BSD, or Apache-2.0; no GPL, AGPL, or LGPL
package was found. Flutter SDK-provided license entries are also exposed by the
in-app license page.

The direct application dependencies include:

| Package | Locked version | License |
| --- | --- | --- |
| cupertino_icons | 1.0.9 | MIT |
| device_info_plus | 13.2.0 | BSD-3-Clause |
| disk_space_2 | 1.0.13 | MIT |
| flutter_riverpod | 2.6.1 | MIT |
| flutter_svg | 2.3.0 | MIT |
| go_router | 17.5.0 | BSD-3-Clause |
| hive | 2.2.3 | Apache-2.0 |
| path_provider | 2.1.6 | BSD-3-Clause |
| permission_handler | 13.0.1 | MIT |
| shared_preferences | 2.5.5 | BSD-3-Clause |

This is a dependency-license review, not a legal opinion or a review of
ownership rights for the app's own name, branding, or content.

## Release size

The optimized universal APK built for this audit is 60,002,751 bytes
(approximately 57.2 MiB). The APK contains one Android `classes.dex` of
1,787,040 bytes (882,694 bytes compressed), which includes all Android-side
application and plugin code, not only the player. Since there is no otherwise
identical pre-player build for a binary comparison, the player-only delta is an
estimate of about 1 MB; Media3 contributes no native libraries or codecs.
