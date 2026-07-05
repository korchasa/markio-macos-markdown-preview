# Manual checklist — FR-ICON (app icon)

## Setup

- `make app`
- Confirm `.build/Markio.app/Contents/Resources/AppIcon.icns` exists.
- `open .build/Markio.app`

## Checks

- [ ] Dock icon is the Markio document glyph (text lines on a rounded card), not the generic app placeholder.
- [ ] Finder shows the same icon for `Markio.app` (Get Info / icon view).
- [ ] App switcher (⌘-Tab) shows the icon.

> Note: macOS caches icons aggressively. If a stale icon shows, the bundle still
> embeds the correct `AppIcon.icns` (verify with `iconutil` / Get Info); a logout
> or `killall Dock` refreshes the cache.
