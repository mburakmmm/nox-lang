# Text

`aura/text` measures and paints paragraphs with the bundled Noto Sans. Measurement goes through the native font code. Widgets never call Skia themselves.

## Plain text

`Text(value, font_size=32.0)` is the widget that stays in 1.0. The string is configuration. The paragraph on the render object is updated through `set_paragraph` when the configuration changes.

## Inline rich text

`TextRun` and `RichText` carry bold, italic and heading inside one paragraph. That landed in 1.0 and is part of the frozen API. It is not a second widget tree of nested `Text` nodes, because a nested tree cannot share one line’s wrapping.

What is not in 1.0: bidirectional layout, and emoji. A run that needs either of those is outside the contract, not a missing flag.

## Fields

The text field is the editable paragraph: selection on a wrapped line (0.5), clipboard, and IME (0.5 and again for variable line height in 0.7). IME composition is a property of the field’s element, not a global. A second field does not see the first field’s composition string.

## Shaping

ADR-008 records the shaping boundary. The widget passes a string and a style. The text module produces glyphs and advances. Layout then treats the paragraph as a box with a width and a height. If the width constraint changes, the paragraph reflows; the widget does not wrap the string itself.
