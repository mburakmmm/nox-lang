# Layout

Layout widgets live under `aura/layout`. They produce render objects that resolve constraints. They do not paint text and they do not see the shell.

| Widget | Module | Role |
|---|---|---|
| `Padding`, `SizedBox`, `Center` | `boxes` | fixed insets and alignment to the child |
| `Align` | `align` | place a child inside the parent’s box |
| `Row`, `Column` | `flex` | main axis, spacing, `MAIN_MIN` and the other flex sizes |
| `Stack` | `stack` | overlapping children |
| `DecoratedBox` | `decorated` | background, border, radius |
| virtual list | `virtual_list` | builds only the visible rows |

`Center(Column([...], main_size=MAIN_MIN, spacing=16.0))` is the counter’s tree: the column is as tall as its children, the center gives it the window.

## Constraints

The parent passes a minimum and a maximum. The child returns a size inside that range. Aura does not use a second layout system beside constraints. ADR-002 in the Aura repo records that choice.

`Stack` and `Align` are how a custom control is positioned when a row or column is the wrong model. `DecoratedBox` is the box around it. `CustomPaint` (under widgets) is the escape when the decoration is not a rectangle.

## Lists

A virtual list builds rows that intersect the viewport. Chat and the file browser in the examples depend on this: row heights are not all equal, and off-screen rows are not elements. Do not put a thousand `Text` widgets in a `Column` and expect the frame budget from the 0.9 dashboard work to hold.

## Repaint

`repaint.nox` is the boundary that stops a dirty render object from painting its siblings. The counter self-check is the small version of that rule. If a parent is marked dirty because its constraints changed, children repaint; if only a signal changed, only the readers of that signal rebuild.
