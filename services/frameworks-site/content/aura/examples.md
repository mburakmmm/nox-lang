# Examples

Each example is a `noxc run` target and a `--self-check` target. `certify.sh` runs all ten and fails if any check fails. They are the specification of what 1.0 can draw.

| Example | What it locks in |
|---|---|
| `examples/counter` | state, signal, repaint of only the reader |
| `examples/rectangle` | a sized, painted box |
| `examples/todo` | a list of rows and a text field |
| `examples/calculator` | buttons writing a value |
| `examples/proof` | packaged font, PNG and JPEG, opacity, debug bounds, the `badge` view, a native `PlatformView` |
| `examples/notes` | wrapped-line selection, clipboard, IME |
| `examples/settings` | theme invalidation, reading the window |
| `examples/chat` | variable row height, IME |
| `examples/files` | a file tree, reads off the UI thread |
| `examples/dashboard` | implicit animation, golden pixels, frame budget |

```sh
noxc run examples/notes/main.nox -- --self-check
noxc run examples/dashboard/main.nox -- --self-check
```

`examples/proof` is the 0.3 tour kept green: one screen, every primitive that later versions are not allowed to break.

Golden pixels belong to the dashboard check. A paint change that shifts a covered pixel fails certify. That is the intended friction. Update the golden only when the picture is supposed to change.

The benchmark (`./scripts/bench.sh`) times the same family of scenes. It writes phase durations and setup counters. It is not a comparison with another UI toolkit; Aether’s HTTP benchmarks live in the Aether repo, not here.
