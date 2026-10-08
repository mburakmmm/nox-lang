# Testing

`noxc test` finds every file named `*_test.nox` under the current directory, compiles and runs each as its own program, and reports one line per file and a summary.

```sh
noxc test
```

```text
GECTI: /path/mathutil_test.nox

1 gecti, 0 basarisiz (1 toplam)
```

(`GECTI`/`gecti` = "passed", `basarisiz` = "failed"; the wording is currently Turkish, the exit status is the contract: `0` when every file passes, `1` otherwise.)

## Writing tests

A test file is an ordinary Nox program that **fails by raising an exception** (or exiting non-zero). Use [`nox.test`](../stdlib/test.md):

```nox
import nox.test

def double(n: int) -> int:
    return n * 2

nox.test.assert_eq_int(double(2), 4, "double(2)")
nox.test.assert_true(double(0) == 0, "double(0)")
nox.test.assert_eq_str("a" + "b", "ab", "concat")
print("all good")
```

```output
all good
```

For many small checks that should all run even when one fails, use a `TestSuite` and write a JUnit report for CI:

```nox-fragment
suite: TestSuite = TestSuite("mathutil")
suite.check_eq_int("double 2", double(2), 4)
suite.check_eq_int("double 3", double(3), 6)
nox.test.write_junit_xml(suite, "test-results.xml")
if not suite.all_passed():
    nox.os.exit(1)
```

## Importing the code under test

Tests import your modules like any other code (`import mathutil`); run `noxc test` from the project root so the project's `nox.json` is found.

## Testing servers and handlers

An HTTP handler is just a function: call it with a hand-built `HttpRequest` and assert on the `HttpResponse`:

```nox
from nox.http import HttpRequest, HttpResponse
import nox.test

def handle(req: HttpRequest) -> HttpResponse:
    return HttpResponse(200, "hi " + req.target, {})

resp: HttpResponse = handle(HttpRequest("GET", "/x", "", {}, ""))
nox.test.assert_eq_int(resp.status, 200, "status")
nox.test.assert_eq_str(resp.body, "hi /x", "body")
print("ok")
```

```output
ok
```

## Testing the compiler itself

The compiler's own suites — golden source→output tests, IR snapshots, differential tests between backends, fuzzing, concurrency torture — are described in [Testing internals](../internals/testing.md).
