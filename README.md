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
https://github.com/MobileContainer/CrashCam-iOS-SDK
```

or in `Package.swift`:

```swift
.package(url: "https://github.com/MobileContainer/CrashCam-iOS-SDK", from: "1.1.0")
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
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/CrashCam-iOS-SDK/scripts/upload-dsyms.sh"
```

Notes:

- Set **`ENABLE_USER_SCRIPT_SANDBOXING = NO`** on the target — Xcode's script
  sandbox hides the dSYM folder and blocks the upload (the same setting
  Crashlytics requires).
- With stock settings only Release builds produce a dSYM; enable
  *DWARF with dSYM File* for Debug to opt Debug builds in.
- `CRASHCAM_SERVER_URL` accepts several space-separated URLs; each gets every
  dSYM. The script never fails the build — an unreachable server only logs.
- Each DWARF is sent one architecture slice at a time, with the sections
  symbolication never reads (the embedded Swift module ASTs and the variable
  location lists) blanked and the result gzipped: a ~290 MB slice of a large
  Swift app goes out as ~40 MB, so uploads stay under typical proxy body
  limits and finish in minutes instead of timing out. Symbol names, file and
  line info and inline frames are untouched. Needs crash-server from
  2026-09-03 or later; for an older server set `CRASHCAM_RAW_UPLOAD=1`.
- The upload runs in the background, so the build never waits on the network.
  Progress goes to a log file under `~/Library/Logs/CrashCam/`; its path is
  printed in the build log, and **failures are only visible there**. Set
  `CRASHCAM_FOREGROUND=1` to upload synchronously instead — for CI machines
  that may shut down right after the build.
- Slices already uploaded to a server are remembered by UUID in
  `~/Library/Caches/CrashCam/uploaded-dsyms` and skipped, so incremental
  rebuilds upload nothing.
- If the project also makes Debug dSYMs (a project-level *DWARF with dSYM
  File*), every Debug build uploads one too. Keep the phase to Release builds
  by making its first line `[ "$CONFIGURATION" = Release ] || exit 0`.

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

## Screens and elements

Every recorded event says where it happened, so the dashboard can cut a
session into screens and draw heatmaps per screen. Nothing is required from
the app:

- **Automatic screen names.** A `viewDidAppear` hook records a screen change
  whenever the visible view controller changes, resolved through presented,
  navigation, tab, split and page containers. The name is the controller's
  class (`BusJourneyListViewController`); a `UIHostingController` reports its
  root SwiftUI view type (`ContentView`). Disable with
  `CrashCam.shared.automaticScreenTracking = false` (touch-time resolution and
  manual markers still work).
- **Manual names override the automatic ones** wherever a class name is not
  meaningful — SwiftUI navigation destinations, generic containers, an
  anonymous `VStack` root:

  ```swift
  // SwiftUI: on a screen's root view
  CheckoutView().crashCamScreen("Checkout")

  // UIKit: on the controller, e.g. in viewDidLoad
  crashCamScreenName = "Checkout"

  // Anywhere: names whatever is on top right now
  CrashCam.shared.markScreen("Checkout")
  ```

- **Touched elements.** A touch-down records the touched element's class
  (`UIButton`, a custom cell class, `SwiftUI` for SwiftUI content) and its
  `accessibilityIdentifier` when the app set one. Accessibility *labels* and
  text are never recorded.
- **Geometry.** The session-start and screen-change rows carry the window size
  in points and the screen scale, so a viewer can draw the recording to scale.

Recording format: rows gain optional `screen`, `element`, `elementId`,
`screenSize` and `scale` fields, and a `kind: 4` (screen change) row. Older
recordings without them still decode and replay.

## Debug-only replay

- `CrashCam.shared.replayLastSession()` replays the previous crashed session's
  touches in-process.
- Launch arguments: `-CrashCamReplayOnLaunch` replays the app's own last
  recording; `-CrashCamReplayFile <absolute path>` replays a chosen recording
  (Simulator: host paths work directly).
- Replays keep the recorded timing from launch: every recording made with
  1.0.3 or later starts with a session-start marker, and the first touch is
  fired the same time after launch as the user's was (or at once if a manual
  replay starts later than that). Recordings without the marker start ~2s
  after launch.
- A pointer overlay shows every replayed touch: an orange disc that scales in
  on touch-down, follows drags with a fading trail and ripples out on lift,
  drawn in a pass-through window above the app. Set
  `TouchReplayer.shared.showsPointer = false` before replaying to hide it.
- Recordings store raw window coordinates; replaying on a different screen
  size is detected and warned about, never rescaled.

## Requirements

- iOS 15+, Swift Package Manager. Depends on
  [PLCrashReporter](https://github.com/microsoft/plcrashreporter) (fetched
  automatically).
- The upload endpoint should be HTTPS (no ATS exceptions needed). For plain
  HTTP to localhost during development, add the
  `NSAllowsLocalNetworking` ATS exception.
