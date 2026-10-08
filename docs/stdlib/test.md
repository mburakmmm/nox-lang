# nox.test

Assertions and a result-collecting test suite. `noxc test` runs every `*_test.nox` file (see [Testing](../tools/testing.md)); inside those files use the functions below.

```text
import nox.test
from nox.test import TestSuite
```

**Capability:** none.

## Assertions — stop at the first failure

Each function raises an exception when the check fails, ending the test program (and failing `noxc test`).

| Function | Description |
|---|---|
| `assert_eq_int(actual, expected, msg)` | `int` equality |
| `assert_eq_str(actual, expected, msg)` | `str` equality |
| `assert_eq_float(actual, expected, msg)` | exact `float` equality |
| `assert_true(cond, msg)` | `cond` must be `True` |

`msg` names the check in the failure report. (There is one function per type because Nox has no overloading.)

## `TestSuite` — collect results, keep going

A suite records every check instead of raising, so later code — including cleanup — always runs, and it can emit a JUnit XML report for continuous-integration systems.

| Member | Description |
|---|---|
| `TestSuite(name)` | an empty suite |
| `check_eq_int(case_name, actual, expected)`, `check_eq_str(...)`, `check_eq_float(...)` | records a pass or a failure |
| `check_true(case_name, cond)` | records a pass or a failure |
| `total_count()` | number of checks recorded |
| `all_passed()` | whether every check passed |
| `write_junit_xml(suite, path)` | writes the results as JUnit XML to `path` |

```nox
import nox.test
from nox.test import TestSuite

suite: TestSuite = TestSuite("demo")
suite.check_eq_int("add", 1 + 1, 2)
suite.check_eq_str("s", "a", "a")
suite.check_eq_float("f", 1.5, 1.5)
suite.check_true("t", True)
print(suite.total_count(), suite.all_passed())
suite.check_eq_int("bad", 1, 2)
print(suite.total_count(), suite.all_passed())

nox.test.assert_eq_int(3, 3, "ok")
try:
    nox.test.assert_eq_int(3, 4, "values")
except Exception as e:
    print("assertion failed")
```

```output
4 True
5 False
assertion failed
```

## Notes

- Test files are ordinary programs: they print what they like and **fail by raising**. A file that finishes normally passes.
- `nox.test` defines its own `AssertionError` class; catch assertion failures with `except Exception` (the built-in `assert` statement raises the prelude's `AssertionError`).
