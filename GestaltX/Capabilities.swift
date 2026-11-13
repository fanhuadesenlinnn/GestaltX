// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
// Public MobileGestalt key mappings cross-checked against MGKeys, Nugget and mond.
// Preset behavior is independently implemented for GestaltX.
import Foundation

enum CapabilityCategory: String, CaseIterable, Identifiable {
    case display = "Display", device = "Device", ipad = "iPad", intelligence = "Intelligence", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .display: "display"
        case .device: "iphone"
        case .ipad: "ipad.landscape"
        case .intelligence: "sparkles"
        case .advanced: "wrench.and.screwdriver"
        }
    }
    var subtitle: String {
        switch self {
        case .display: "Dynamic Island, Always-On and Liquid Glass"
        case .device: "Charging, buttons and device identity"
        case .ipad: "Stage Manager and app compatibility"
        case .intelligence: "Region and generative model capabilities"
        case .advanced: "Internal features and research settings"
        }
    }
}

struct Capability: Identifiable {
    let id: String
    let category: CapabilityCategory
    let title: String
    let detail: String
    let keys: [String]
    var caution = false
    /// Per-key values for presets that are not a plain Boolean 1, such as the
    /// parallax switch (0) or the AOD flipbook count.
    var values: [String: Any]? = nil
    var availableChoices: [PresetChoice] {
        // Preserve the device-specific Siri capability type and allow recovery from older overrides.
        id == "siriOnDevice" ? [.keep, .disable, .removeAdded] : PresetChoice.allCases
    }
    var requiresEnableConfirmation: Bool { id == "storage" }
    var effectHint: String {
        switch id {
        case "ai", "siriAIMode", "siriOnDevice", "audioIntelligence", "personalTranslator", "photosCleanUp",
             "handwritingSynthesis", "alwaysListeningSiri":
            "Restart required. Apple Intelligence also depends on device and region."
        case "pencil": "Restart the device, then reopen Settings. Pencil hardware support is still required."
        case "bootChime", "chargeLimit", "tapToWake", "cameraControl", "actionButton",
             "internal", "storage", "srd", "aodHighLuminance", "aodFlipbook", "aodFlipbookCount",
             "pwm", "displayPort", "collisionSOS", "internalSettings":
            "A device restart may be required."
        default: "Respring first. Restart the device if the change does not appear."
        }
    }
    var enabled: Any { id == "ipadApps" ? [1, 2] : NSNumber(value: 1) }
    func apply(_ choice: PresetChoice, to document: inout GestaltDocument, restoringFrom snapshot: DocumentSnapshot) {
        guard choice != .keep, availableChoices.contains(choice) else { return }
        for key in keys {
            switch choice {
            case .keep: break
            case .enable: document.set(values?[key] ?? enabled, for: key)
            case .disable: document.set(snapshot.originalValue(for: key), for: key)
            case .removeAdded: document.set(nil, for: key)
            }
        }
        if id == "dynamicIsland", choice == .disable || choice == .removeAdded {
            restoreDynamicIslandLayout(in: &document, from: snapshot)
        }
    }

    func restoreDynamicIslandLayout(in document: inout GestaltDocument, from snapshot: DocumentSnapshot) {
        guard id == "dynamicIsland", var artwork = document.extra[GestaltKeys.artwork] as? [String: Any] else { return }
        let original = snapshot.originalValue(for: GestaltKeys.artwork)
        let originalArtwork = original as? [String: Any]
        // Layout and model-name presets share this dictionary. Restore only the
        // layout member so unrelated artwork edits keep their current values.
        artwork["ArtworkDeviceSubType"] = originalArtwork?["ArtworkDeviceSubType"]
        document.set(artwork.isEmpty && original == nil ? nil : artwork, for: GestaltKeys.artwork)
    }
    static let all: [Self] = [
        .init(id: "dynamicIsland", category: .display, title: "Dynamic Island", detail: "Enable the alternate Dynamic Island capability.", keys: ["YlEtTtHlNesRBMal1CqRaA"]),
        .init(id: "aod", category: .display, title: "Always-On Display", detail: "Display behavior depends on the panel. May increase power use and burn-in risk.", keys: ["2OOJf1VhaM7NxfRok3HbWQ", "j8/Omm6s1lsmTDFsXjsBfA"], caution: true),
        .init(id: "aodVibrancy", category: .display, title: "AOD Vibrancy", detail: "Adjust Always-On rendering capabilities.", keys: ["ykpu7qyhqFweVMKtxNylWA"]),
        .init(id: "aodHighLuminance", category: .display, title: "High-Luminance Always-On Display", detail: "Allow Always-On Display to reach a higher brightness level.", keys: ["7brdL5xrEUWnlF9C0kdg5A"]),
        .init(id: "aodFlipbook", category: .display, title: "Always-On Display Flipbook", detail: "Enable AOD flipbook widgets on the Lock Screen.", keys: ["aoJSd/MXk7M40NgXTM6x+g"]),
        .init(id: "aodFlipbookCount", category: .display, title: "AOD Flipbook Count", detail: "Set how many AOD flipbook entries are allowed. Experimental; the accepted range varies by build.", keys: ["qqrspu7CpuPdZwSDxNY+Fg"], caution: true, values: ["qqrspu7CpuPdZwSDxNY+Fg": NSNumber(value: 3)]),
        .init(id: "parallax", category: .display, title: "Disable Wallpaper Parallax", detail: "Stop the wallpaper from moving with device motion.", keys: ["UIParallaxCapability"], values: ["UIParallaxCapability": NSNumber(value: 0)]),
        .init(id: "hdrPhotoDisplay", category: .display, title: "HDR Photo Display", detail: "Enable true HDR rendering for photos.", keys: ["a1r7npIrhXsZ7SmKRKC1eA"]),
        .init(id: "pwm", category: .display, title: "Pulse Width Modulation", detail: "Advertise PWM display support. Actual dimming behavior depends on the panel.", keys: ["6IejgN+1Fmu5/QrZFOIeNw"], caution: true),
        .init(id: "displayPort", category: .display, title: "DisplayPort Output", detail: "Advertise DisplayPort output support. Compatible hardware is still required.", keys: ["CoWnN4xo783YGn4wLrUatA"], caution: true),
        .init(id: "liquidGlass", category: .display, title: "Liquid Glass Low-Power Rendering", detail: "Use the low-performance rendering capability on iOS 26 and later.", keys: ["SAGvsp6O6kAQ4fEfDJpC4Q"]),
        .init(id: "bootChime", category: .device, title: "Boot & Shutdown Chime", detail: "Expose the startup and shutdown sound capability.", keys: ["QHxt+hGLaBPbQJbXiUJX3w"]),
        .init(id: "chargeLimit", category: .device, title: "Charge Limit", detail: "Show charging limit settings. Actual charging control depends on hardware.", keys: ["37NVydb//GP/GrhuTN+exg"]),
        .init(id: "tapToWake", category: .device, title: "Tap to Wake", detail: "Expose tap-to-wake on devices where it is hidden.", keys: ["yZf3GTRMGTuwSV/lD7Cagw"]),
        .init(id: "cameraControl", category: .device, title: "Camera Control", detail: "Show Camera Control settings. Does not add a physical button.", keys: ["CwvKxM2cEogD3p+HYgaW0Q", "oOV1jhJbdV3AddkcCg0AEA"]),
        .init(id: "actionButton", category: .device, title: "Action Button", detail: "Show the Action Button settings page.", keys: ["cT44WE1EohiwRzhsZ8xEsw"]),
        .init(id: "collisionSOS", category: .device, title: "Collision SOS", detail: "Show collision detection in Emergency SOS settings. Hardware support is still required.", keys: ["HCzWusHQwZDea6nNhaKndw"]),
        .init(id: "audioMix", category: .device, title: "Audio Mix", detail: "Enable the audio mix capability for supported media.", keys: ["aVL5GE3tx0LSCI/ErfrJGA"]),
        .init(id: "spatialFaceTimeAudio", category: .device, title: "Spatial FaceTime Audio", detail: "Enable spatial audio playback for FaceTime.", keys: ["/EVOCjM/Nmb2roP5ebtEFA"]),
        .init(id: "pencil", category: .ipad, title: "Apple Pencil", detail: "Expose Apple Pencil settings. Hardware support is still required.", keys: ["yhHcB0iH0d1XzPO/CFd3ow"]),
        .init(id: "stageManager", category: .ipad, title: "Stage Manager", detail: "Expose Stage Manager support. Layout behavior varies by device.", keys: ["qeaj75wk3HF4DwQ8qbIi7g"], caution: true),
        .init(id: "ipadApps", category: .ipad, title: "iPad App Compatibility", detail: "Allow iPad app compatibility types on iPhone.", keys: ["9MZ5AdH43csAUajl/dU+IQ"]),
        .init(id: "ai", category: .intelligence, title: "Apple Intelligence Capability", detail: "Set the generative models capability. Availability also depends on hardware, region and Apple services.", keys: ["A62OafQ85EJAiiqKn4agtg"]),
        .init(id: "siriAIMode", category: .intelligence, title: "Siri AI Mode", detail: "Set SiriMode to 2 without spoofing hardware. Experimental; resource downloads and availability are not guaranteed.", keys: [GestaltKeys.siriMode], caution: true, values: [GestaltKeys.siriMode: NSNumber(value: 2)]),
        .init(id: "siriOnDevice", category: .intelligence, title: "On-Device Siri", detail: "Siri uses a device-specific capability type. Changing it may affect the Apple Intelligence Siri interface. Keep the current value or restore the recorded original.", keys: ["K/R1GfGfCkXvEhaPS2Vrng"], caution: true),
        .init(id: "audioIntelligence", category: .intelligence, title: "Audio Intelligence", detail: "Advertise the iOS 27 audio intelligence capability.", keys: ["rb2tKZxlj0Gm2tBmUQSLqQ"], caution: true),
        .init(id: "personalTranslator", category: .intelligence, title: "Personal Translator", detail: "Advertise the personal translator capability.", keys: ["M1n2sAqf33NAOgZRGxQYBA"], caution: true),
        .init(id: "photosCleanUp", category: .intelligence, title: "Photos Clean Up", detail: "Advertise the photos inpainting (Clean Up) capability.", keys: ["XNCjqOupLM/S8fNyxRNQTA"], caution: true),
        .init(id: "handwritingSynthesis", category: .intelligence, title: "Handwriting Synthesis", detail: "Advertise the handwriting synthesis model capability.", keys: ["YgYIIViDt1kgzyIsIV61vA"], caution: true),
        .init(id: "alwaysListeningSiri", category: .intelligence, title: "Always-Listening Hey Siri", detail: "Advertise always-listening Hey Siri support.", keys: ["TusANsf9Lfe3P/9fIXXSrQ"], caution: true),
        .init(id: "internal", category: .advanced, title: "Apple Internal Features", detail: "Expose internal menus. Some system services may behave differently.", keys: ["EqrsVvjcYDdxHBiQmGhAWw"], caution: true),
        .init(id: "storage", category: .advanced, title: "Internal Build", detail: "Changes the system-wide InternalBuild flag, not just storage information. System services may behave differently. Revert restores the recorded original value.", keys: ["LBJfwOEzExRxzlAnSuI7eg"], caution: true),
        .init(id: "srd", category: .advanced, title: "Security Research Device", detail: "Change the SRD capability flag. This does not turn the device into an Apple SRD.", keys: ["XYlJKKkj2hztRP1NWWnhlw"], caution: true),
        .init(id: "internalSettings", category: .advanced, title: "Internal Settings Bundle", detail: "Expose Apple's internal settings bundle. Some system services may behave differently.", keys: ["Oji6HRoPi7rH7HPdWVakuw"], caution: true),
    ]
}

enum PresetChoice: Int, CaseIterable, Identifiable {
    case keep, enable, disable, removeAdded
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .keep: "Keep Current"
        case .enable: "Enable"
        case .disable: "Disable (Restore Original)"
        case .removeAdded: "Remove Added Fields"
        }
    }
}

struct RegionPreset: Identifiable {
    let id: String
    let title: String
    let code: String
    let info: String
    static let all: [Self] = [
        .init(id: "keep", title: "Keep Current", code: "", info: ""),
        .init(id: "US", title: "United States", code: "LL", info: "LL/A"),
        .init(id: "HK", title: "Hong Kong", code: "ZA", info: "ZA/A"),
        .init(id: "JP", title: "Japan", code: "J", info: "J/A"),
        .init(id: "CN", title: "China (Mainland)", code: "CH", info: "CH/A"),
        .init(id: "TW", title: "Taiwan", code: "TA", info: "TA/A"),
        .init(id: "UK", title: "United Kingdom", code: "B", info: "B/A"),
        .init(id: "CA", title: "Canada", code: "C", info: "C/A")
    ]
}

struct ModelPreset: Identifiable {
    static let restoration = Capability(id: "modelNumber", category: .intelligence, title: "Model Number",
                                        detail: "", keys: [GestaltKeys.modelNumber])
    let id: String
    let title: String
    let value: String
    static let all: [Self] = [
        .init(id: "keep", title: "Keep Current", value: ""),
        .init(id: "A3472", title: "A3472 — 18 Pro · United States", value: "A3472"),
        .init(id: "A3713", title: "A3713 — 18 Pro · Canada / Japan", value: "A3713"),
        .init(id: "A3714", title: "A3714 — 18 Pro · Other regions", value: "A3714"),
        .init(id: "A3715", title: "A3715 — 18 Pro · China mainland", value: "A3715"),
        .init(id: "A3473", title: "A3473 — 18 Pro Max · United States", value: "A3473"),
        .init(id: "A3716", title: "A3716 — 18 Pro Max · Canada / Japan", value: "A3716"),
        .init(id: "A3717", title: "A3717 — 18 Pro Max · Other regions", value: "A3717"),
        .init(id: "A3718", title: "A3718 — 18 Pro Max · China mainland", value: "A3718"),
        .init(id: "A3260", title: "A3260 — Air · United States / Canada", value: "A3260"),
        .init(id: "A3516", title: "A3516 — Air · Japan", value: "A3516"),
        .init(id: "A3517", title: "A3517 — Air · Other regions", value: "A3517"),
        .init(id: "A3518", title: "A3518 — Air · China mainland", value: "A3518")
    ]
}

struct FieldDraft: Identifiable {
    let id = UUID()
    var originalKey: String?
    var key = ""
    var kind = PlistValueKind.string
    var text = ""
    private let originalValue: Any?
    private let originalText: String?

    init(originalKey: String? = nil, key: String = "", kind: PlistValueKind = .string,
         text: String = "", originalValue: Any? = nil) {
        self.originalKey = originalKey; self.key = key; self.kind = kind; self.text = text
        self.originalValue = originalValue
        self.originalText = originalValue == nil ? nil : text
    }

    func parsedValue() throws -> Any {
        // Text formats can be less precise than a binary plist, including Date
        // values nested inside an XML array or dictionary. A no-op edit or a
        // key rename must preserve the exact value that populated the editor.
        if let originalValue, kind == PlistValueKind.detect(originalValue),
           text == originalText {
            return originalValue
        }
        return try kind.parse(text)
    }
}
