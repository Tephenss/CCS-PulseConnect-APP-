# iOS Setup on a Mac

The iOS project is present, but a successful Xcode build has not yet been verified. Follow this checklist on the Mac before installing on an iPhone.

## Before transferring the project

- Copy the full `CCS PulseConnect(APP)` folder to the Mac.
- `lib/config/env.dart` is intentionally ignored by Git and exists only in the local app folder. Copy that file securely to the same path on the Mac. Do not replace it with `env.example.dart` unless you fill in the real app configuration, and do not commit it.
- Do not rely on Windows-generated `ios/Flutter/Generated.xcconfig`, `.dart_tool`, `build`, or `ios/Pods`. The Mac will regenerate platform-specific files.
- The actual `ios/Runner/GoogleService-Info.plist` is not in this folder; only an example file is present. Firebase-dependent features need the real iOS configuration before testing.

## Prepare Flutter and Xcode

1. Install Flutter 3.38.4 or later, Xcode, and CocoaPods on the Mac. In Terminal, run `flutter doctor -v` and resolve the Xcode/toolchain issues it reports.
2. From the project root, run `flutter pub get`.
3. Run `cd ios && pod install`, then return to the project root.
4. Open `ios/Runner.xcworkspace` in Xcode. Open the workspace, not `Runner.xcodeproj`, so the CocoaPods dependencies are loaded.

## Configure Firebase for iOS

1. In the existing Firebase project, register an iOS app with bundle ID `com.ccspulseconnect.pulseConnectApp`.
2. Download that app's `GoogleService-Info.plist`, place it at `ios/Runner/GoogleService-Info.plist`, and add it to the Runner target in Xcode if it does not appear in the project navigator.
3. For push notifications, add the Apple APNs authentication key to the Firebase iOS app and enable the Push Notifications capability for Runner. Configure Background Modes only if the app's background notification behavior requires it.

The app currently catches Firebase initialization errors so some screens may still open without Firebase, but Firestore and push-dependent features are not considered ready until the iOS Firebase app is configured.

## Sign and install on an iPhone

1. Connect and trust the iPhone on the Mac. In Xcode, select the Runner target, open Signing & Capabilities, choose the Apple account/team, and keep Automatically manage signing enabled.
2. Enable Developer Mode on the iPhone, select it as Xcode's run destination, and run the Runner scheme.
3. Test login, event loading, photo selection, QR scanning, teacher attendance, and notifications on the physical device. Camera access is used for both profile photos and event QR scanning.

## Project compatibility notes

- The Runner target is iOS 13.0. The Firebase pods resolved from the current locked dependencies declare iOS 13.0 as their minimum, so the Podfile is aligned to 13.0 without raising the app's existing deployment target.
- If Flutter/Firebase packages are upgraded later and CocoaPods requires a higher iOS target, update the Podfile and Runner target together and check the iOS versions of the intended test devices first.
- `pubspec.lock` requires Dart 3.11.4 or later and Flutter 3.38.4 or later.
- This setup does not change the app's backend, authentication, or screen flows. The Firebase plist, Apple signing team, and APNs key must come from the owner's Firebase/Apple accounts and cannot be safely generated in this Windows workspace.