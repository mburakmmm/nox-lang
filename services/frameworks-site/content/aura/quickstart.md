# A counter

The counter in `examples/counter` is the smallest stateful Aura page. `CounterPage` is a `StatefulWidget`. It does not store the count. `create_state` returns a `CounterState`, and the state owns a `Signal`.

Each widget passes a stable `type_id` into `super().__init__`. `alloc_type_id()` hands those out for the process. They are not serialized.

```nox
from aura.controls import Button
from aura.layout import Center, Column
from aura.layout.flex import MAIN_MIN
from aura.text import Text
from aura.widgets import BuildContext, Signal, State, StatefulWidget, StatelessWidget, Widget
from aura.widgets.type_ids import alloc_type_id

TYPE_COUNTER: int = alloc_type_id()
TYPE_COUNT_READ: int = alloc_type_id()

class CountRead(StatelessWidget):
    source: Signal

    def __init__(self, source: Signal) -> None:
        super().__init__(TYPE_COUNT_READ, None)
        self.source = source

    def build(self, context: BuildContext) -> Widget:
        return Text(str(self.source.get()), font_size=48.0)

class CounterState(State):
    count: Signal

    def __init__(self) -> None:
        super().__init__()
        self.count = Signal(0)

    def increment(self) -> None:
        self.count.set(self.count.get() + 1)

    def build(self, context: BuildContext) -> Widget:
        return Center(Column([
            Text("Aura", font_size=32.0),
            CountRead(self.count),
            Button("Continue", self.increment),
        ], main_size=MAIN_MIN, spacing=16.0))

class CounterPage(StatefulWidget):
    def __init__(self) -> None:
        super().__init__(TYPE_COUNTER, None)

    def create_state(self) -> State:
        return CounterState()
```

`main.nox` calls `run_app(CounterPage())`. With `--self-check` it mounts the same page into a `Binding` of 800×600, posts a click at the button’s center, and checks three things: the label became `"1"`, the static header’s paint mark stayed 0, and the header element’s rebuild count stayed 0 while the reader rebuilt.

That split is the point of `CountRead`. The header widget did not close over the signal, so it is not rebuilt and not repainted. The reader did.

`State` is not generic. Nox 2.0 has no `isinstance`, and a monomorphized generic class cannot be another class’s base. The count is a field on `CounterState`, not a type argument.
