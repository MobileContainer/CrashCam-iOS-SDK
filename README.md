# CrashCam-iOS

Record-and-replay crash reproduction for iOS. CrashCam records every touch your
app receives (and text-edit *lengths* — never content), keeps the log durably
on disk across a crash, and on the next launch uploads the crash report, the
exact input sequence that triggered it, and app/device metadata to a
[crash-server](https://crashcam.kerimcaglar.com) dashboard — where the report
is symbolicated against your uploaded dSYMs and grouped by crash reason. In
Debug builds the recorded session can be replayed **in-process** with
frame-accurate timing to reproduce the crash on demand.

- Touches are appended synchronously to disk *before* dispatch, so the fatal
  tap is always captured — nothing runs inside the signal handler.
- Text fields contribute only character counts; replay supplies substitute
  text. No user-entered content is ever stored or uploaded.
- The private-API touch synthesis used by the replayer is compiled **only in
  Debug** — Release builds contain none of it.

## Installation

Add the package in Xcode (**File → Add Package Dependencies…**):

```
https://github.com/<your-github>/CrashCam-iOS
```

or in `Package.swift`:

```swift
.package(url: "https://github.com/<your-github>/CrashCam-iOS", from: "1.0.0")
```

The library product is `CrashCam-iOS`; the module you import is `CrashCam`.

## Integration

### 1. Bootstrap (both lifecycles)

Call once at launch, with your server endpoint and this app's upload token:

```swift
import CrashCam

CrashCam.shared.bootstrap(
    uploadEndpoint: URL(string: "https://<your-server>/api/crashes"),
    uploadToken: "<this app's token>"
)
```

Leave `uploadEndpoint` nil to record locally without uploading.

### 2. Install the tracking window

**UIKit lifecycle** — create the window in your SceneDelegate:

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = TrackingWindow(windowScene: windowScene)
    window.rootViewController = MyRootViewController()
    self.window = window
    window.makeKeyAndVisible()
}
```

**SwiftUI lifecycle** — subclass the provided adaptor delegate:

```swift
class AppDelegate: CrashCamAppDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                         [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        CrashCam.shared.bootstrap(uploadEndpoint: ..., uploadToken: ...)
        return true
    }
}

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Crash reporting and upload work without the tracking window; only touch
recording needs it.

### 3. dSYM upload build phase (symbolicated reports)

Add a **Run Script** phase to your app target so every build with a dSYM
uploads it to the server (reports are symbolicated server-side, matched by
binary UUID):

```sh
export CRASHCAM_SERVER_URL="https://<your-server>"
export CRASHCAM_UPLOAD_TOKEN="<this app's token>"
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/CrashCam-iOS/scripts/upload-dsyms.sh"
```

Notes:

- Set **`ENABLE_USER_SCRIPT_SANDBOXING = NO`** on the target — Xcode's script
  sandbox hides the dSYM folder and blocks the upload (the same setting
  Crashlytics requires).
- With stock settings only Release builds produce a dSYM; enable
  *DWARF with dSYM File* for Debug to opt Debug builds in.
- `CRASHCAM_SERVER_URL` accepts several space-separated URLs; each gets every
  dSYM. The script never fails the build — an unreachable server only logs.

### 4. Server-side: mint the app's token

On the crash-server host, add an entry to `data/tokens.json` (created if
missing; hot-reloaded, no restart needed):

```json
{
  "<openssl rand -hex 24>": { "app": "com.your.bundleid", "label": "Your App" }
}
```

Uploads carrying that token are attributed to that bundle id (the token's
identity overrides whatever the client claims), and the app appears as its own
card on the dashboard.

## Debug-only replay

- `CrashCam.shared.replayLastSession()` replays the previous crashed session's
  touches in-process.
- Launch arguments: `-CrashCamReplayOnLaunch` replays the app's own last
  recording ~2s after launch; `-CrashCamReplayFile <absolute path>` replays a
  chosen recording (Simulator: host paths work directly).
- Recordings store raw window coordinates; replaying on a different screen
  size is detected and warned about, never rescaled.

## Requirements

- iOS 15+, Swift Package Manager. Depends on
  [PLCrashReporter](https://github.com/microsoft/plcrashreporter) (fetched
  automatically).
- The upload endpoint should be HTTPS (no ATS exceptions needed). For plain
  HTTP to localhost during development, add the
  `NSAllowsLocalNetworking` ATS exception.
# CrashCam-iOS-SDK
# CrashCam-iOS-SDK
