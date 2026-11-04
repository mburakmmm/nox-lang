# 12. Testing

Nox has testing built in. A test is just a program that **fails by raising an exception**; `noxc test` runs every file named `*_test.nox` and reports which
ones passed. There is no framework to install and no special syntax to learn.

## A first test

Put the code under test in a module and the test next to it, inside a project (a directory with a `nox.json`, as in [chapter 8](08-modules-and-packages.md); `noxc init` creates one). Suppose `textutil.nox` contains a function that turns a title into a URL slug:

```nox-fragment
# textutil.nox
def slugify(title: str) -> str:
    out: str = ""
    for ch in title.lower():
        if ch.isalnum():
            out += ch
        elif len(out) > 0 and out[len(out) - 1] != "-":
            out += "-"
    while len(out) > 0 and out[len(out) - 1] == "-":
        out = out[:len(out) - 1]
    return out
```

and `textutil_test.nox` checks it with the assertions from [`nox.test`](../stdlib/test.md):

```nox-fragment
# textutil_test.nox
import nox.test
from textutil import slugify

nox.test.assert_eq_str(slugify("Hello, World!"), "hello-world", "punctuation")
nox.test.assert_eq_str(slugify("  Nox  2.0  "), "nox-2-0", "spaces and digits")
nox.test.assert_eq_str(slugify("!!!"), "", "nothing left")
print("slugify ok")
```

Run all tests from the project root, or only those whose file name matches a word:

```sh
noxc test
noxc test textutil
```

```text
PASSED: /path/to/textutil_test.nox

1 passed, 0 failed (1 total)
```

The exit status is the contract: `0` when every file passes, `1` otherwise — so `noxc test` drops straight into a CI job.

## What a failure looks like

An assertion that fails raises an exception that names the check, which is why every assertion takes a message. Here a deliberately wrong expectation is
caught so that you can see the message:

```nox
import nox.test

def double(n: int) -> int:
    return n * 2

try:
    nox.test.assert_eq_int(double(2), 5, "double(2)")
except Exception as e:
    print("caught:", e.message)
```

```output
caught: double(2): expected 5, got 4
```

In a real test file you do not catch it: the exception ends the program with status 1 and `noxc test` marks the file `FAILED`, printing the message.

## Testing that something raises

There is no `assert_raises`; a `try`/`except` says the same thing and reads clearly:

```nox
import nox.test

def parse_port(text: str) -> int:
    port: int = int(text)
    if port < 1 or port > 65535:
        raise ValueError("port out of range")
    return port

nox.test.assert_eq_int(parse_port("8080"), 8080, "valid port")

raised: bool = False
try:
    parse_port("70000")
except ValueError as e:
    raised = True
nox.test.assert_true(raised, "70000 is rejected")
print("both checks passed")
```

```output
both checks passed
```

## Keep going after a failure: `TestSuite`

Assertions stop at the first failure. When you want every check to run — and a report at the end — collect them in a `TestSuite`:

```nox
import nox.test
from nox.test import TestSuite

def clamp(x: int, low: int, high: int) -> int:
    if x < low:
        return low
    if x > high:
        return high
    return x

suite: TestSuite = TestSuite("clamp")
suite.check_eq_int("below", clamp(-5, 0, 10), 0)
suite.check_eq_int("inside", clamp(7, 0, 10), 7)
suite.check_eq_int("above", clamp(99, 0, 10), 10)
suite.check_true("bounds ordered", 0 < 10)
print(suite.total_count(), "checks, all passed:", suite.all_passed())
```

```output
4 checks, all passed: True
```

`nox.test.write_junit_xml(suite, "test-results.xml")` writes the results in the JUnit format that CI systems display.

## Testing a web handler without a server

A handler is an ordinary function from `HttpRequest` to `HttpResponse`, so you can call it directly — no port, no network:

```nox
import nox.test
from nox.http import HttpRequest, HttpResponse

def handle(req: HttpRequest) -> HttpResponse:
    if req.target == "/health":
        return HttpResponse(200, "ok", {})
    return HttpResponse(404, "not found", {})

ok: HttpResponse = handle(HttpRequest("GET", "/health", "", {}, ""))
missing: HttpResponse = handle(HttpRequest("GET", "/nope", "", {}, ""))
nox.test.assert_eq_int(ok.status, 200, "health status")
nox.test.assert_eq_int(missing.status, 404, "unknown path")
print("handler ok")
```

```output
handler ok
```

## Habits that pay off

- **One behaviour per check, with a message** that says what you were testing: `"punctuation"` beats `"test 3"`.
- **Test the edges** — empty input, one element, the largest value, the error path — not only the happy case.
- **Keep tests independent.** Create files under `/tmp` with a name of your own and delete them at the end, as the previous chapter did.
- **Run `noxc test` before every commit.** It is fast because each test file is compiled and run as its own small program.

Next: [13. Generics and protocols](13-generics-and-protocols.md).
