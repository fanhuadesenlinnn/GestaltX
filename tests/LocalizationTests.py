import json
from pathlib import Path
import unicodedata
import unittest


ROOT = Path(__file__).resolve().parents[1]
CAPABILITY_KEYS = (
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


class LocalizationTests(unittest.TestCase):
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
