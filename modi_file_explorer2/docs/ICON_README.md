Adaptive launcher icon notes

To fix the adaptive icon layering issue you reported, provide two separate assets:

1) Foreground (glyph-only, transparent background)
   - Path: `assets/branding/logo_foreground.png`
   - Requirements: PNG, ideally 1024x1024, transparent background. The visible glyph should be centered and occupy roughly the center 66% of the canvas so it remains visible under circular/squircle masks.

2) Background
   - We use a solid color in `pubspec.yaml` (hex `#0D47A1`). Alternatively you can supply a full-bleed PNG and set `adaptive_icon_background` to its path.

Steps to apply after adding `logo_foreground.png`:

```bash
flutter pub get
# Regenerate launcher icons
flutter pub run flutter_launcher_icons:main
# Uninstall the app from your device/emulator
adb uninstall com.example.modi_file_explorer2
# Clean and reinstall
flutter clean
flutter pub get
flutter run -d <device-id>
```

Notes:
- The foreground must be transparent (no background baked in). If the provided `logo.png` contains the navy rounded square baked into the image, that must *not* be used as the adaptive foreground.
- If you want, supply both `logo_foreground.png` and `logo_background.png` (the latter as a full-bleed image) and set `adaptive_icon_background` to the file path instead of the hex color.
- After reinstall, test on multiple launcher masks (circle and squircle) to ensure glyph centering and correct padding.
