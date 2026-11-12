<p align="center">
  <img src="GestaltX/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="GestaltX" width="112" height="112">
</p>

<h1 align="center">GestaltX</h1>

[![Version](https://img.shields.io/badge/version-1.0.5-blue)](https://github.com/huamidev/GestaltX)
[![Platform](https://img.shields.io/badge/iOS-27.x-black?logo=apple)](#compatibility)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://github.com/huamidev/GestaltX)
[![License](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

[English](README.md) · [简体中文](README_ZH-CN.md) · [日本語](README_JA.md)

A MobileGestalt editor for iPhone and iPad. Developed by [huamidev](https://github.com/huamidev).

## Features

| Category | Presets and tools |
| --- | --- |
| Display | Dynamic Island capability and layout, Always-On Display, AOD Vibrancy, high-luminance AOD, AOD flipbook, HDR photo display, wallpaper parallax, Liquid Glass low-power rendering, experimental PWM and DisplayPort flags |
| Device | Model name, boot/shutdown chime, charge limit, tap to wake, Camera Control settings, Action Button settings, Collision SOS, Audio Mix, Spatial FaceTime audio |
| iPad | Apple Pencil settings, Stage Manager capability, iPad app compatibility |
| Intelligence | Independent region-code options, Apple Intelligence capability flag, on-device Siri, Audio Intelligence, Personal Translator, Photos Clean Up, Handwriting Synthesis, always-listening Hey Siri, and sales-region options for activation attempts on China-mainland devices |
| Advanced | Apple internal feature flags, the system-wide InternalBuild flag with explicit enable confirmation, internal settings bundle, Security Research Device flag |
| Field editor | Read, search, add, edit, and remove `CacheExtra` fields; local plist import/export; String, Integer, Real, Boolean, Data, Date, Array, and Dictionary values |
| Changes | Automatic reading and manual re-read, staged before/after review, verified writes, per-preset restore |
| Backups | Automatic initial backup before device editing, backup before every write, original-value records; open, export, restore, and delete |
| Logs & respring | Actual exploit-stage logs and manual NeoSpring respring |

Usually, changing the region code is enough to try enabling AI; there is no need to change Sales Region. Selecting United States for Region Code sets `RegionCode` to `LL` and keeps the sales-region suffix. You can also choose China (Mainland), Hong Kong, Taiwan, Japan or the United Kingdom. Sales Region and Region Code can be applied together: the sales suffix follows Sales Region, while the code follows Region Code.

*If you previously changed Sales Region, restore your device’s original sales region and apply it first.*

Disabling a preset or using its Revert button restores the recorded original values and types. Keys that were originally absent are removed. If an older change has no original record, use Remove Added Fields only when you know those fields were added.

Presets modify capability flags; actual effects depend on the device and OS. China-mainland devices can use the Apple Intelligence and region options to attempt activation; availability also depends on the model, OS version, and Apple services.

## Compatibility

Supports **iOS / iPadOS 27.x**. **iOS / iPadOS 26.x is not supported for on-device MobileGestalt access.** Powered by [worse_query](https://github.com/forcequitOS/worse_query). SystemGroup access requires iOS 27; available features depend on the device and OS. Local plist editing is also supported.

Signing requires a certificate and provisioning profile with at least one usable App Group. Sign the app and its embedded share extension with at least one **common App Group**, and keep the extension when re-signing. Both processes detect their actual signed App Groups at runtime. Distributed IPAs carry ad-hoc signatures with these entitlements embedded so SideStore and AltStore can detect them when re-signing; they are not signed with a developer certificate.

## Download

Download the IPA from [Releases](https://github.com/huamidev/GestaltX/releases/latest).
Some users report incomplete downloads with Safari on iOS 27. If the file is
reported as damaged or cannot be extracted, download it again; several attempts
may be needed. Try another browser if it persists. The cause has not been confirmed.

## Import a plist

In Files or another app, select a MobileGestalt plist, tap **Share**, and choose **GestaltX**. The share extension reads the supplied file and hands it to the app through the shared App Group. Return to GestaltX if it does not open automatically. The app checks a device-bound proof from a GestaltX export, or at least two unique identifiers obtained from this device, then asks you to confirm the import. Files that cannot be verified are rejected. Previously imported files are never used as the reference for device identity.

Some original plists contain no unique device identifiers. Export a copy from GestaltX on this device first: its verification key stays in the device-only Keychain and is never included in the file.

Shared files are checked at launch and on return to the foreground. Pending edits are preserved until you save or discard them. Confirmed imports open as local documents. **MG Control** supports adding, editing, renaming and deleting typed keys and values. Use **Restore Imported Plist** to restore a verified file to this device; restoration requires a matching system cache layout and an additional confirmation, backs up the current file, and verifies the write. Restart the device afterward.

## Language support

GestaltX follows your iOS language settings, with English as the default and fallback. Persian includes right-to-left layout support.

| Language | Locale |
| --- | --- |
| English | `en` |
| 简体中文 — Simplified Chinese | `zh-Hans` |
| 繁體中文（台灣）— Traditional Chinese (Taiwan) | `zh-Hant-TW` |
| 繁體中文（香港）— Traditional Chinese (Hong Kong) | `zh-Hant-HK` |
| Tiếng Việt — Vietnamese | `vi` |
| Русский — Russian | `ru` |
| فارسی — Persian | `fa` |
| 한국어 — Korean | `ko` |
| Español — Spanish | `es` |

## Credits

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)
- [neonmodder123](https://github.com/neonmodder123)
- [skadz108](https://github.com/skadz108)
- [rooootdev — NeoSpring](https://github.com/rooootdev/neospring)
- [Nouvborne — Ketamine](https://github.com/Nouvborne/Ketamine)
- [PoomSmart — MGKeys](https://github.com/PoomSmart/MGKeys)
- [leminlimez — Nugget](https://github.com/leminlimez/Nugget)
- [rooootdev — mond](https://github.com/rooootdev/mond)
- [frs0n — GestaltEdit](https://github.com/frs0n/GestaltEdit)

## Disclaimer

For security research and educational purposes only. Use only on devices you own or are authorized to manage.

Back up your data before making changes. Modifying MobileGestalt may cause system instability or require a device restore. You are responsible for the changes you apply and the resulting risks.

## License

[GNU GPL v3](LICENSE) · Copyright © 2026 huamidev.

## Star History

<a href="https://www.star-history.com/#huamidev/GestaltX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date&amp;theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
    <img width="480" alt="GestaltX Star History" src="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
  </picture>
</a>
