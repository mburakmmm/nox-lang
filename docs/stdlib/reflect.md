# nox.reflect

Queries the metadata that [decorators](../language/decorators.md) record, and class constructor signatures — the raw material for frameworks that wire routes, controllers and dependencies from annotations.
Decorators never change behaviour on their own; `nox.reflect` is how a framework reads what they say.

```text
import nox.reflect
```

**Capability:** none.

The complete function table, a worked example and the meaning of each record kind are on the [Decorators and reflection](../language/decorators.md#reading-metadata-noxreflect) page. In summary:

| Group | Functions |
|---|---|
| Records | `decorator_count()`, `decorator_kind(i)`, `decorator_name(i)`, `decorator_target_name(i)`, `decorator_owner(i)` |
| Arguments | `decorator_arg_count(i)`, `decorator_arg_kind(i, j)`, `decorator_arg(i, j)`, `decorator_arg_int(i, j)`, `decorator_arg_bool(i, j)`, `decorator_arg_list_len(i, j)`, `decorator_arg_list_item(i, j, k)` |
| Signatures | `decorator_param_count(i)`, `decorator_param_name(i, k)`, `decorator_param_type(i, k)`, `decorator_return_type(i)` |
| Classes | `class_count()`, `class_name(i)`, `class_index(name)`, `class_init_param_count(i)`, `class_init_param_name(i, k)`, `class_init_param_type(i, k)` |
| Handlers | `decorator_is_handler(i)`, `decorator_handler(i)`, `router_from_decorators()` |

```nox
import nox.reflect

@route("/hello", 3, True)
def hello(a: int) -> int:
    return a

print(nox.reflect.decorator_count(), nox.reflect.decorator_name(0), nox.reflect.decorator_target_name(0))
print(nox.reflect.decorator_arg(0, 0), nox.reflect.decorator_arg_int(0, 1), nox.reflect.decorator_arg_bool(0, 2), nox.reflect.decorator_param_name(0, 0))
print(nox.reflect.decorator_kind(0), nox.reflect.decorator_arg_kind(0, 1), nox.reflect.decorator_return_type(0))
```

```output
1 route hello
/hello 3 True a
0 1 int
```

Record kinds: `0` function, `1` class, `2` method; argument kinds: `0` string, `1` int, `2` bool, `3` string list.
