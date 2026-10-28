# Roadmap

The binding contract is `roadmap.md` in the Aura repository. `AGENTS.md` invariants hold for every version. A version is finished before the next one starts. 1.0 is finished. The rows after it are not implemented.

## Done

0.4 through 1.0, as listed on the [overview](/docs/). Certify on macOS, Win32, X11 and Wayland is the gate that closed 1.0, together with the API freeze, inline rich text, and `packages/badge`.

## Not in this release

| Item | Status |
|---|---|
| iOS shell, keyboard, touch | planned as 1.1 and later |
| Android | planned after the iOS shell |
| GPU surface | planned as 1.5 |
| Web | outside the contract |
| Hot reload | outside the contract |
| Slivers | outside the contract |
| Bidirectional text, emoji | not in 1.0 |

Do not import a module for a row that is not done. The tree under `aura/` is the 1.0 surface.

## Frozen names

`Text` does not get renamed. `TextRun` and `RichText` are the inline path. `Stack`, `Align`, `Inherited`, `MouseRegion`, `GestureDetector`, `DecoratedBox` and `CustomPaint` stay the custom-UI kit. A new widget family is an addition with its own `type_id`, not a change to those names.

`type_id` values come from `alloc_type_id()` and are not written to disk. A saved file must not store them and expect the next process to agree.

## Nox stays the language

Aura does not fork the compiler. Language questions — types, ownership, errors, the standard library — are answered at [noxlang.com](https://noxlang.com). This site answers the widget, element and render trees, and the shells that paint them.
