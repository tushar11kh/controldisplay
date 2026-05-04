# DisplayToggleBar

DisplayToggleBar is a small macOS menu-bar app for Apple Silicon Macs that lists online displays and lets you enable or disable them from the menu bar.

The app uses macOS display configuration APIs plus the private `CGSConfigureDisplayEnabled` symbol. This is the same class of OS-level display toggle used by tools that disable an internal display while keeping the Mac awake. It is not DDC/CI monitor power control.

## Behavior

- Shows each online display in the menu bar menu.
- Green switches are currently active displays.
- Grey switches are online but disabled from the active layout.
- Disabling is greyed out when only one display is active.
- Built-in displays are labelled as `Built-in`.

## Build

```sh
./scripts/build-app.sh
```

The app bundle is created at:

```text
DisplayToggleBar.app
```

You can also run it directly during development:

```sh
swift run DisplayToggleBar
```

## Notes

Because the display enable/disable function is private, macOS may change or block it in future releases. The app is intended for local use, not App Store distribution.
