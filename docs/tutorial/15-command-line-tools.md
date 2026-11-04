# 15. Command-line tools

Nox compiles to a single native executable with no runtime to install, which makes it a pleasant language for command-line tools: they start instantly and
you can hand the binary to someone else. This chapter builds the pieces every tool needs — arguments, environment variables, input, exit codes and running
other programs.

## Arguments and environment

`nox.os.arg_count()` counts the command-line arguments **including** the program name at index 0, so the first real argument is `arg(1)`. Environment variables
come from `getenv`, which raises `OsError` if the variable is not set:

```nox
import nox.os
from nox.os import OsError

def env_or(name: str, fallback: str) -> str:
    try:
        return nox.os.getenv(name)
    except OsError as e:
        return fallback

print("arguments (including the program name):", nox.os.arg_count())
print(env_or("NOX_TUTORIAL_GREETING", "hello"))
nox.os.set_var("NOX_TUTORIAL_GREETING", "salut")
print(env_or("NOX_TUTORIAL_GREETING", "hello"))
```

```output
arguments (including the program name): 1
hello
salut
```

Run a program with arguments by putting them after `--` for `noxc run`, or simply after the executable name once you have built it:

```sh
noxc run greet.nox -- Ada Turing
noxc build -o greet greet.nox && ./greet Ada Turing
```

## Parsing flags by hand

There is no argument-parsing framework to learn: a loop over the arguments is usually all you need. Keep the parsing in a function that takes a plain
`list[str]` — that way you can test it, as in [chapter 12](12-testing.md), without launching the program:

```nox
class Options:
    verbose: bool
    count: int
    names: list[str]

    def __init__(self) -> None:
        self.verbose = False
        self.count = 1
        self.names = []

def parse_options(args: list[str]) -> Options:
    opts: Options = Options()
    i: int = 0
    while i < len(args):
        arg: str = args[i]
        if arg == "-v" or arg == "--verbose":
            opts.verbose = True
        elif arg == "-n" or arg == "--count":
            i += 1
            opts.count = int(args[i])
        else:
            opts.names.append(arg)
        i += 1
    return opts

opts: Options = parse_options(["-v", "--count", "2", "Ada", "Turing"])
for round in range(opts.count):
    for name in opts.names:
        if opts.verbose:
            print("round", round + 1, "- hello,", name)
        else:
            print("hello,", name)
```

```output
round 1 - hello, Ada
round 1 - hello, Turing
round 2 - hello, Ada
round 2 - hello, Turing
```

In the real program you would build the list from `nox.os.arg(1)` up to `arg_count() - 1`.

## Reading input

`input()` (no arguments — print your own prompt) reads one line from standard input. It is how an interactive tool talks to the person at the keyboard, and what lets your program sit at the end of
a pipe:

```nox-fragment
print("Your name?")
name: str = input()
print("hello,", name)
```

```sh
echo "Ada" | ./greet
```

## Exit codes and messages

A command-line tool communicates success or failure through its **exit status**: `0` is success, anything else is an error that scripts can test. An uncaught
exception exits with `1`; to choose the code yourself, call `nox.os.exit`. Send diagnostics to the log or console modules rather than mixing them into your
program's real output:

```nox-fragment
import nox.os
import nox.console

def main_logic() -> int:
    if nox.os.arg_count() < 2:
        nox.console.error("usage: greet <name>")
        return 2
    print("hello,", nox.os.arg(1))
    return 0

nox.os.exit(main_logic())
```

`exit` ends the process immediately without running pending `defer`s or `finally` blocks, so close what you opened first.

## Running other programs

`nox.process` runs an external program and captures its output. There is no shell involved, so arguments are never re-interpreted — a space or a quote in an
argument is just a character:

```nox
from nox.process import Command, Output, ProcessError

out: Output = Command("echo").arg("two words").arg("and 'quotes'").run()
print(out.status, out.stdout.strip())

failing: Output = Command("sh").arg("-c").arg("exit 3").run()
print("exit status", failing.status, "success:", failing.success())

try:
    Command("no-such-program-xyz").run()
except ProcessError as e:
    print("could not start it")
```

```output
0 two words and 'quotes'
exit status 3 success: False
could not start it
```

A program that exits non-zero is not an error — inspect `status`. `ProcessError` means it could not be run at all. `set_timeout(ms)` stops a program that hangs.

## Putting it together

A complete, tiny tool — `wordcount.nox` — that counts the lines and words in the files named on the command line:

```nox-fragment
import nox.os
import nox.fs
from nox.fs import FsError

def count_words(text: str) -> int:
    n: int = 0
    for line in text.split("\n"):
        for word in line.split(" "):
            if len(word) > 0:
                n += 1
    return n

status: int = 0
for i in range(1, nox.os.arg_count()):
    path: str = nox.os.arg(i)
    try:
        text: str = nox.fs.read_to_string(path)
        print(len(text.split("\n")) - 1, "lines,", count_words(text), "words:", path)
    except FsError as e:
        print("wordcount: cannot read", path)
        status = 1
nox.os.exit(status)
```

```sh
noxc build -o wordcount wordcount.nox
./wordcount notes.txt missing.txt
echo $?
```

Next: [16. WebAssembly and the browser](16-webassembly.md).
