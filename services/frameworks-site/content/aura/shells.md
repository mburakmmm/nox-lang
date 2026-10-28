# Shells

`aura/platform` is the bridge. `native/macos`, `native/windows` and `native/linux` are the shells. `native/skia` plays the scene. Widgets do not import those directories.

## What a shell does

- Opens the window and the framebuffer.
- Sends pointer, key, IME and size events into the binding.
- Presents the scene Skia rasterized.

ADR-005 is the platform split. ADR-013 is the host shells. The same self-check source runs on each host; the shell is the only file that changes.

## Linux

The Linux build needs Wayland, Xkbcommon, X11, D-Bus and wayland-protocols. Both Wayland and X11 are certified. The app does not pick a backend in widget code.

## Windows

Skia is linked with MSVC. The Nox program is linked with MinGW `cc`, which is the same C compiler Nox already uses for Windows binaries. The two linkers meet at the shell library the build script produces.

## macOS

The macOS shell is the third certified host. `build_host.sh` on a Mac produces it. Window size and the scale factor are read back through the platform bridge; the Settings example (0.6) is the one that displays them.

## Scene and paint

ADR-007 is the scene layer: a list of paint commands, not a live Skia canvas handed to widgets. ADR-012 is the Skia paint player that consumes that list. `CustomPaint` records into the scene. It does not hold an `SkCanvas`.

## Plugins and extra windows

`packages/badge` is the worked example of a second package. The app calls `register_view` to mount it. ADR-014 is that bridge. `PlatformView` is the slot for a native child view; `examples/proof` shows one.

ADR-011 records multi-window. A second window is a second binding, not a widget that happens to call the OS. 1.0’s examples are single-window unless the example itself opens another.

## Navigation

ADR-010 is the navigator: a stack of pages on one window. `aura/widgets/navigator.nox` is that stack. It is not a URL router. Aura does not serve HTTP.
