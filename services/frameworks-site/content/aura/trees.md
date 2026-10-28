# Three trees

Aura keeps three trees because a widget is rebuilt often and a render object must not be. This is ADR-001 in the Aura repository.

## Widget

A widget is configuration. `build` returns a new tree of widgets. Two widgets are the same slot when their `type_id` matches and their `Key` is compatible. Without a key, sibling index is the identity.

`ValueKey` holds text. An integer key is `IntValueKey`. `ObjectKey` and `GlobalKey` use an in-process integer. Global keys are stored in parallel lists, not a `dict[int, Element]`: the cycle collector was observed not to finish on a dictionary closed over that way.

## Element

The element is the long-lived object. It holds the lifecycle, the dirty bit and the child list. Reconciliation is a prefix scan, a suffix scan, a keyed middle, then an unkeyed index fallback.

`rebuild_count` on the element is what the counter self-check reads. A widget that did not depend on the changed signal keeps a rebuild count of 0.

## RenderObject

`RenderBox` lays out under constraints, paints, and hit-tests. Configuration is written onto it through virtual setters: `set_paragraph`, `set_button`, `set_sized`, `set_padding`, `set_color`, `set_flex_style`. A new widget family takes its own `type_id` and, if the render object needs new data, a new setter.

Paint is incremental. The counter’s header is a different render object from the count text, and a click that only changes the count leaves the header’s paint mark at 0.

## What was rejected

A runtime type test, and a generic `State[T]` base, cannot be expressed in Nox 2.0’s class model. Folding the widget and the render object into one class would have stored layout state on the configuration, which is rebuilt. The three trees stay separate. A change to that split is a new ADR, not a quiet edit.
