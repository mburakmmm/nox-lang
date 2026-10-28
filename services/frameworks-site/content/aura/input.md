# Input

`aura/input` owns the pointer, the keyboard, the gesture arena, focus and drop. Controls in `aura/controls` are widgets on top of that: `Button`, `Toggle`, `Draggable` and `DropTarget`.

## Hit testing

The render tree answers “which box contains this point”, in front-to-back order. The counter self-check does not invent a button id. It clicks the center of the button’s box:

```nox
x: float = button.absolute_x() + button.width / 2.0
y: float = button.absolute_y() + button.height / 2.0
binding.post_click(x, y)
```

`post_click` is the headless path. A real shell delivers the same event from the platform.

## Gestures

`GestureDetector` and `MouseRegion` are the widgets for a control that is not a `Button`. The arena resolves a drag versus a tap so a parent scroll view and a child button do not both win. `MouseRegion` is hover and cursor, not the click.

## Focus and keys

Focus is a single element in the tree. Key events go there. 1.0’s desktop shells deliver keyboard input; the mobile keyboard work is 1.1 and later and is not in this release. Do not read the roadmap’s later rows as available modules.

## Drag and drop

`Draggable` and `DropTarget` are the controls. A drop target accepts a payload the drag published. The file browser example uses the same hit-testing rules; it does not install a second pointer path for files.

## UI thread

The shell calls the frame on one thread. ADR-006 is that contract. The file browser (0.8) may read the filesystem off that thread and deliver the result back as data the next frame builds from. A widget `build` does not start a thread. If you need a slow read, follow that example: do the read outside, then `set` a `Signal` the page already holds.
