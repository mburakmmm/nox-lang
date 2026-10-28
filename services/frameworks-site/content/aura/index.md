# Overview

Aura is the desktop UI framework for [Nox](https://noxlang.com). Application code builds a widget tree. The framework turns that into a long-lived element tree, a render tree that lays out and paints, and a scene the shell presents in a window.

**Version @@VERSION@@.** The public API is frozen. `Text` stays. `TextRun` and `RichText` carry inline bold, italic and heading. Custom UI is built from `Stack`, `Align`, `Inherited`, `MouseRegion`, `GestureDetector`, `DecoratedBox` and `CustomPaint`.

A widget is configuration. An element holds identity, lifecycle and dirty state. A `RenderObject` lays out, paints and hit-tests. The three are not interchangeable.

## Layout of the repository

Dependencies point downward. Graphics and platform code do not import widgets. `extern def` appears only in the shell, the graphics backend and text measurement.

| Path | Role |
|---|---|
| `aura/foundation` | geometry, color, constraints |
| `aura/widgets` | `Widget`, `Element`, `State`, `Signal`, `Key` |
| `aura/rendering` | `RenderBox`, `PipelineOwner`, the scene |
| `aura/layout` | padding, sized box, center, align, row, column, stack, decorated box, virtual list |
| `aura/text` | text, `TextRun`, `RichText`, paragraph, text field |
| `aura/input` | pointer, key, gesture arena, focus, drop |
| `aura/controls` | button, toggle, drag and drop |
| `aura/platform` | the shell bridge |
| `native/macos`, `native/windows`, `native/linux` | host shells |
| `native/skia` | Skia raster player |
| `packages/badge` | a second package an app mounts with `register_view` |

The Nox compiler is not modified from this repository. Aura is a consumer of Nox 2.0.

## What 1.0 includes

The binding contract is `roadmap.md` in the Aura repo, and the gate is `scripts/certify.sh`: the test suite plus ten headless self-checks, on macOS, Win32, X11 and Wayland.

| Version | Delivery |
|---|---|
| 0.4 | The same self-check on three desktop shells |
| 0.5 | Notes, selection on a wrapped line, clipboard, IME |
| 0.6 | Settings, theme invalidation, window metrics |
| 0.7 | Chat, variable line height, IME |
| 0.8 | File browser, reads off the UI thread |
| 0.9 | Dashboard, implicit animation, golden pixels, frame budget |
| 1.0 | API freeze, inline rich text, `packages/badge` |

Web, hot reload and slivers are outside that contract. Inline bold, italic and heading are in 1.0. Bidirectional text and emoji are not.

## License

The framework sources do not have a chosen license yet. `native/fonts/NotoSans-Regular.ttf` is SIL Open Font License 1.1. Skia is a third-party archive the build script downloads; it is not committed.
