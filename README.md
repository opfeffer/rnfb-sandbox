# RNFB SPM: archive signature-collision fix misses the `-ios-simulator` slice

Minimal repro for `@react-native-firebase/app`'s iOS SPM integration.

`firebase_spm.rb` → `rnfirebase_fix_spm_archive_signature_collision` (L1325–1355) adds the Run Script phase
**"[RNFB] Remove duplicate Firebase/Google SPM binary xcframework signature files"** to the app target. That phase
only deletes `"${CONFIGURATION_BUILD_DIR}"/<name>.xcframework-ios.signature`.

An `xcodebuild archive` for a **simulator** destination stages `<name>.xcframework-ios-simulator.signature`
instead, so the phase deletes nothing and the Archive step fails with the same "item with the same name already
exists" collision that the workaround was written to prevent.

This is what Bitrise's `xcode-build-for-simulator` step (3.x) runs: `xcodebuild archive -destination
"generic/platform=iOS Simulator"` with an xcconfig that sets `CODE_SIGNING_ALLOWED=NO` and
`COMPILER_INDEX_STORE_ENABLE=NO`.

> **Version note:** the report is against **27.1.0**. This repro pins **27.0.0** because of a local
> package-age policy (27.1.0 was under 7 days old when this was built). `firebase_spm.rb` is identical between
> 27.0.0 and 27.1.0 apart from one comment line (`12.19.0` → `12.19.3` at L183). The signature-fix function and
> `RNFIREBASE_SPM_SIGNATURE_FIX_ARTIFACT_NAMES` are byte-identical.

## Project

- Expo SDK 57 blank TypeScript template (`expo-template-blank-typescript@57.0.33`), CNG via `expo prebuild`
- `@react-native-firebase/app` + `@react-native-firebase/analytics` 27.0.0, with the `@react-native-firebase/app` config plugin
- `expo-build-properties` with `ios.useFrameworks: "dynamic"`
- `GoogleService-Info.plist` is a **placeholder with fake values** (bundle id `com.example.rnfbsigrepro`). It is
  build-only, and the app never runs.
- `ci.xcconfig` mirrors the Bitrise xcconfig:
  ```
  CODE_SIGNING_ALLOWED=NO
  COMPILER_INDEX_STORE_ENABLE=NO
  ```

`ios/` is generated and git-ignored, and so are `node_modules/`, `build/` and `.expo/`. Leave those out when you
zip the project. `.npmrc` sets `ignore-scripts=true`; no dependency install script is needed
for this repro.

## Run

```bash
./repro.sh
```

`repro.sh` deletes `ios/` and `build/`, runs `npm ci`, `expo prebuild --platform ios`, and `pod install`, and then
runs these cases, each with a fresh `-derivedDataPath`/`-archivePath` under `./build`. Logs go to
`build/<case>.log`.

| # | Command | Expected | Observed |
|---|---------|----------|----------|
| 1 | `xcodebuild archive … -destination "generic/platform=iOS Simulator" -xcconfig ci.xcconfig` (stock RNFB) | fail | **fail**, exit 70 |
| 2 | Same as case 1 but with `build` instead of `archive` | pass | **pass**, `BUILD SUCCEEDED` |
| 3 | Case 1 after applying `patches/@react-native-firebase+app+27.0.0.patch` and running `pod install` again | pass | **pass**, `ARCHIVE SUCCEEDED` |
| 4 | (optional, manual) Case 1 with analytics excluded from iOS autolinking (stock RNFB) | pass | **pass**, `ARCHIVE SUCCEEDED` |

Common arguments:

```
-workspace ios/RNFBSigRepro.xcworkspace -scheme RNFBSigRepro -configuration Release
-destination "generic/platform=iOS Simulator" -xcconfig ci.xcconfig
-derivedDataPath build/dd-<case> [-archivePath build/<case>.xcarchive]
```

### Case 1: observed error

```
xcodebuild: error: “GoogleAdsOnDeviceConversion.xcframework-ios-simulator.signature” couldn’t be copied to “Signatures” because an item with the same name already exists.: The operation couldn’t be completed. File exists
(exit 70; xcodebuild prints no "** ARCHIVE FAILED **" banner for this error)
```

The RNFB phase does run during the archive (`PhaseScriptExecution [RNFB]\ Remove\ duplicate…` in the log), but
it only removes `*-ios.signature` files, and none exist for a simulator archive. These signature files were
staged twice, once in the app target's `CONFIGURATION_BUILD_DIR` and once under the `RNFBAnalytics` pod's build
dir:

```
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/FirebaseAnalytics.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/GoogleAdsOnDeviceConversion.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/GoogleAppMeasurement.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/GoogleAppMeasurementIdentitySupport.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/RNFBAnalytics/FirebaseAnalytics.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/RNFBAnalytics/GoogleAdsOnDeviceConversion.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/RNFBAnalytics/GoogleAppMeasurement.xcframework-ios-simulator.signature
ArchiveIntermediates/RNFBSigRepro/BuildProductsPath/Release-iphonesimulator/RNFBAnalytics/GoogleAppMeasurementIdentitySupport.xcframework-ios-simulator.signature
```

### Case 2: observed

```
** BUILD SUCCEEDED **   (exit 0)
```

`build` never copies signatures into an `.xcarchive`, so the failure is specific to the Archive action.

### Case 3: observed

After the patch and `pod install`, the generated phase also contains the
`rm -f "${CONFIGURATION_BUILD_DIR}"/<name>.xcframework-ios-simulator.signature` lines.

```
** ARCHIVE SUCCEEDED **   (exit 0)
```

The archive's `Signatures/` then contains exactly one copy of each simulator signature:

```
FirebaseAnalytics.xcframework-ios-simulator.signature
GoogleAdsOnDeviceConversion.xcframework-ios-simulator.signature
GoogleAppMeasurement.xcframework-ios-simulator.signature
GoogleAppMeasurementIdentitySupport.xcframework-ios-simulator.signature
```

### Case 4 (optional): analytics excluded from autolinking

Not part of `repro.sh`. With stock RNFB, analytics was excluded from iOS autolinking by temporarily adding this
`react-native.config.js`, followed by `pod install` and the case 1 command:

```js
module.exports = { dependencies: { '@react-native-firebase/analytics': { platforms: { ios: null } } } };
```

Observed: `RNFBAnalytics` was gone from `Podfile.lock`, and the result was `** ARCHIVE SUCCEEDED **` (exit 0). The
archive had **no `Signatures/` directory at all**, so without Analytics no SPM binary xcframework signature
is copied into the archive, and nothing can collide.

## Patch

`patches/@react-native-firebase+app+27.0.0.patch` (applied with `patch-package`):

```diff
-      rm_lines = RNFIREBASE_SPM_SIGNATURE_FIX_ARTIFACT_NAMES.map do |name|
-        "rm -f \"${CONFIGURATION_BUILD_DIR}\"/#{name}.xcframework-ios.signature"
+      rm_lines = RNFIREBASE_SPM_SIGNATURE_FIX_ARTIFACT_NAMES.flat_map do |name|
+        %w[ios ios-simulator].map { |slice| "rm -f \"${CONFIGURATION_BUILD_DIR}\"/#{name}.xcframework-#{slice}.signature" }
       end
```

The fallback warning text around L810–814 also only mentions `…xcframework-ios.signature`. It may be worth
updating that wording as well.

## Versions

| | |
|---|---|
| `@react-native-firebase/app`, `/analytics` | 27.0.0 (report: 27.1.0, same `firebase_spm.rb` logic) |
| expo | 57.0.31 |
| expo-build-properties | 57.0.22 |
| react-native | 0.86.3 |
| react | 19.2.3 |
| Xcode | 26.6 (17F113) |
| CocoaPods | 1.16.2 (run with `LANG=en_US.UTF-8`) |
| Ruby | 3.3.10 |
| Node / npm | 24.22.1 / 11.19.1 |
| macOS | 26.7.1, Apple M4 Pro |

Resolved SPM packages (from `SourcePackages/workspace-state.json`): firebase-ios-sdk 13.0.0,
GoogleAppMeasurement 13.0.1, google-ads-on-device-conversion-ios-sdk 3.7.0, GoogleUtilities 8.1.5,
abseil-cpp-binary 1.2025051202.0, grpc-binary 1.83.1, gtm-session-fetcher 5.3.1, nanopb 2.30910.1,
promises 2.4.1, leveldb 1.22.5, app-check 12.0.0, interop-ios-for-google-sdks 101.0.0,
GoogleDataTransport 10.1.1.

Note: with SDK 57's default `EXPO_USE_PRECOMPILED_MODULES=true`, `pod install` prints
`[Expo] Disabling USE_FRAMEWORKS for 71 pods (…, RNFBAnalytics, RNFBApp, …)`, so those pods link statically even
though `ios.useFrameworks` is `"dynamic"`. This is stock SDK 57 behaviour, and I did not change it here.

<details><summary><code>react-native info</code></summary>

Expo projects do not include `@react-native-community/cli`, so this was run with a separately installed
`@react-native-community/cli@20.2.0` against this project. Home paths are redacted.

```
System:
  OS: macOS 26.7.1
  CPU: (14) arm64 Apple M4 Pro
  Memory: 1.09 GB / 48.00 GB
  Shell:
    version: "5.9"
    path: /bin/zsh
Binaries:
  Node:
    version: 24.22.1
    path: ~/.nvm/versions/node/v24.22.1/bin/node
  Yarn:
    version: 1.22.22
    path: ~/.nvm/versions/node/v22.18.0/bin/yarn
  npm:
    version: 11.19.1
    path: ~/.nvm/versions/node/v24.22.1/bin/npm
  Watchman:
    version: 2025.12.15.00
    path: /opt/homebrew/bin/watchman
Managers:
  CocoaPods:
    version: 1.16.2
    path: ~/.rbenv/shims/pod
SDKs:
  iOS SDK:
    Platforms:
      - DriverKit 25.5
      - iOS 26.5
      - macOS 26.5
      - tvOS 26.5
      - visionOS 26.5
      - watchOS 26.5
  Android SDK:
    API Levels:
      - "31"
      - "33"
      - "34"
      - "35"
      - "36"
    Build Tools:
      - 30.0.3
      - 33.0.0
      - 34.0.0
      - 35.0.0
      - 36.0.0
      - 36.1.0
    System Images:
      - android-36.1 | Google Play ARM 64 v8a
      - android-36 | 16 KB Page Size Google Play ARM 64 v8a
      - android-37.0 | Pre-Release 16 KB Page Size Google Play ARM 64 v8a
    Android NDK: Not Found
IDEs:
  Android Studio: 2025.2 AI-252.27397.103.2522.14514259
  Xcode:
    version: 26.6/17F113
    path: /usr/bin/xcodebuild
Languages:
  Java:
    version: 21.0.8
    path: /usr/bin/javac
  Ruby:
    version: 3.3.10
    path: ~/.rbenv/shims/ruby
npmPackages:
  "@react-native-community/cli": Not Found
  react:
    installed: 19.2.3
    wanted: 19.2.3
  react-native:
    installed: 0.86.3
    wanted: 0.86.3
  react-native-macos: Not Found
npmGlobalPackages:
  "*react-native*": Not Found
Android:
  hermesEnabled: Not found
  newArchEnabled: Not found
iOS:
  hermesEnabled: Not found
  newArchEnabled: Not found
```
</details>

```
$ xcodebuild -version
Xcode 26.6
Build version 17F113

$ pod --version
1.16.2
```
