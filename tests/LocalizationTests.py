import json
from pathlib import Path
import re
import unicodedata
import unittest


ROOT = Path(__file__).resolve().parents[1]
CAPABILITY_KEYS = (
    "Siri AI Mode",
    "Set SiriMode to 2 without spoofing hardware. Experimental; resource downloads and availability are not guaranteed.",
    "High-Luminance Always-On Display",
    "Allow Always-On Display to reach a higher brightness level.",
    "Always-On Display Flipbook",
    "Enable AOD flipbook widgets on the Lock Screen.",
    "AOD Flipbook Count",
    "Set how many AOD flipbook entries are allowed. Experimental; the accepted range varies by build.",
    "Disable Wallpaper Parallax",
    "Stop the wallpaper from moving with device motion.",
    "HDR Photo Display",
    "Enable true HDR rendering for photos.",
    "Pulse Width Modulation",
    "Advertise PWM display support. Actual dimming behavior depends on the panel.",
    "DisplayPort Output",
    "Advertise DisplayPort output support. Compatible hardware is still required.",
    "Collision SOS",
    "Show collision detection in Emergency SOS settings. Hardware support is still required.",
    "Audio Mix",
    "Enable the audio mix capability for supported media.",
    "Spatial FaceTime Audio",
    "Enable spatial audio playback for FaceTime.",
    "Internal Settings Bundle",
    "Expose Apple's internal settings bundle. Some system services may behave differently.",
    "On-Device Siri",
    "Siri uses a device-specific capability type. Changing it may affect the Apple Intelligence Siri interface. Keep the current value or restore the recorded original.",
    "Audio Intelligence",
    "Advertise the iOS 27 audio intelligence capability.",
    "Personal Translator",
    "Advertise the personal translator capability.",
    "Photos Clean Up",
    "Advertise the photos inpainting (Clean Up) capability.",
    "Handwriting Synthesis",
    "Advertise the handwriting synthesis model capability.",
    "Always-Listening Hey Siri",
    "Advertise always-listening Hey Siri support.",
)
LOCALE_SCRIPTS = {
    "zh-Hant-TW": "CJK",
    "zh-Hant-HK": "CJK",
    "vi": "LATIN",
    "ru": "CYRILLIC",
    "fa": "ARABIC",
    "ko": "HANGUL",
}
ALL_LOCALE_SCRIPTS = {
    "en": {"LATIN"},
    "zh-Hans": {"LATIN", "CJK"},
    "zh-Hant-TW": {"LATIN", "CJK"},
    "zh-Hant-HK": {"LATIN", "CJK"},
    "vi": {"LATIN"},
    "ru": {"LATIN", "CYRILLIC"},
    "fa": {"LATIN", "ARABIC"},
    "ko": {"LATIN", "HANGUL"},
    "es": {"LATIN"},
    "ja": {"LATIN", "CJK", "HIRAGANA", "KATAKANA", "KATAKANA-HIRAGANA", "IDEOGRAPHIC"},
}


class LocalizationTests(unittest.TestCase):
    def test_all_locales_have_complete_valid_translations(self):
        catalog = json.loads((ROOT / "GestaltX/Localizable.xcstrings").read_text())
        self.assertEqual(catalog["sourceLanguage"], "en")
        placeholders = re.compile(r"%(?:\d+\$)?(?:ll|l)?[diufsg@]")
        for key, entry in catalog["strings"].items():
            localizations = entry["localizations"]
            self.assertEqual(set(localizations), set(ALL_LOCALE_SCRIPTS), key)
            for locale, localization in localizations.items():
                with self.subTest(locale=locale, key=key):
                    unit = localization["stringUnit"]
                    self.assertEqual(unit["state"], "translated")
                    value = unit["value"]
                    self.assertTrue(value.strip())
                    self.assertEqual(value, value.strip())
                    self.assertCountEqual(placeholders.findall(key), placeholders.findall(value))
                    scripts = {
                        unicodedata.name(character).split()[0]
                        for character in value if character.isalpha()
                    }
                    self.assertLessEqual(scripts, ALL_LOCALE_SCRIPTS[locale])
                    if locale != "en" and len(key.split()) >= 3 and key != "GNU GPL v3":
                        self.assertNotEqual(value, key, "Untranslated prose")

    def test_directly_used_localization_keys_exist(self):
        catalog = json.loads((ROOT / "GestaltX/Localizable.xcstrings").read_text())["strings"]
        pattern = re.compile(
            r'\b(?:(?:L|text|GestaltFailure|CustomizationFailure)\(|SharedPlistError\(key:\s*)'
            r'"([^"\\]*(?:\\.[^"\\]*)*)"'
        )
        for directory in ("GestaltX", "ShareExtension", "Shared"):
            for path in (ROOT / directory).rglob("*.swift"):
                for key in pattern.findall(path.read_text()):
                    if "\\(" not in key:
                        with self.subTest(file=str(path.relative_to(ROOT)), key=key):
                            self.assertIn(key, catalog)

    def test_capability_translations_use_locale_script(self):
        for locale, script in LOCALE_SCRIPTS.items():
            translations = json.loads((ROOT / "localization" / f"{locale}.json").read_text())
            for key in CAPABILITY_KEYS:
                with self.subTest(locale=locale, key=key):
                    scripts = {
                        unicodedata.name(character).split()[0]
                        for character in translations[key]
                        if character.isalpha()
                    }
                    self.assertIn(script, scripts)
                    self.assertLessEqual(scripts, {"LATIN", script})

    def test_catalog_matches_translation_sources(self):
        catalog = json.loads((ROOT / "GestaltX/Localizable.xcstrings").read_text())["strings"]
        for path in sorted((ROOT / "localization").glob("*.json")):
            translations = json.loads(path.read_text())
            self.assertEqual(set(translations), set(catalog), path.stem)
            for key, value in translations.items():
                with self.subTest(locale=path.stem, key=key):
                    unit = catalog[key]["localizations"][path.stem]["stringUnit"]
                    self.assertEqual(unit["state"], "translated")
                    self.assertEqual(unit["value"], value)


if __name__ == "__main__":
    unittest.main()
