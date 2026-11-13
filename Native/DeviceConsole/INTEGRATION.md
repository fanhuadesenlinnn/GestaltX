# Wiring the native device console into the GestaltX app

The app builds and runs without this step; pairing/capture simply report
"not available" until the native console is linked and enabled.

## 1. Prerequisites (on a build machine with Xcode)

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
brew install cmake    # aws-lc builds from C source; nasm too on x86_64 hosts
```

## 2. Build the xcframework

```bash
cd Native/DeviceConsole
./build-xcframework.sh
# → Native/DeviceConsole/build/GXDeviceConsole.xcframework  (git-ignored)
```

## 3. Add it to the Xcode project (GestaltX target only)

- Drag `Native/DeviceConsole/build/GXDeviceConsole.xcframework` into the project,
  add to the **GestaltX** target, "Do Not Embed" (it is a static library).
- Build Settings → **Other Linker Flags**: add `-lc++`.
- The bridging header already imports `GXDeviceConsole.h` (copied to
  `GestaltX/GXDeviceConsole.h`; keep it identical to `include/GXDeviceConsole.h`).

## 4. Enable the code path

Build Settings → **Swift Compiler - Custom Flags → Active Compilation Conditions**:
add `GXDEVICECONSOLE` (Debug and Release). Without it, `DeviceConsole` reports
`.unavailable` and no `gx_*` symbol is referenced, so the app links without the
library.

## 5. Info.plist

Already set in `Configuration/App-Info.plist`:
`NSLocalNetworkUsageDescription`, `NSBonjourServices`
(`_remotepairing-pairable-host._tcp`), and
`BGTaskSchedulerPermittedIdentifiers` (`$(PRODUCT_BUNDLE_IDENTIFIER).console.continued.*`).

## 6. On device

Pair once in Settings › Privacy & Security › Developer Mode (pair with the
broadcast host; the exact path varies by iOS version), start a loopback VPN
(e.g. LocalDevVPN), then Start Capture and trigger a notification in the target
app.
