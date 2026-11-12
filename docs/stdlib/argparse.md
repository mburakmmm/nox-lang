# nox.argparse

Command-line argument parsing, modelled on Python's `argparse`.

```text
import nox.argparse
from nox.argparse import ArgumentParser, Namespace, ArgumentError
```

**Capability:** none. The parser works on a `list[str]`, so it is pure; pass it the program's arguments yourself (for example from `nox.os.arg_count()` / `nox.os.arg(i)`).

Types are static, so the result is a `Namespace` you query by name instead of an object with dynamic attributes. An option's name (its *dest*) is the long name without the dashes, with `-` turned into `_` (`--max-count` is `max_count`); a positional's name is the name you gave it.

## Declaring arguments

| Method | Meaning |
|---|---|
| `ArgumentParser(prog, description="")` | a new parser |
| `add_flag(short, long, help="")` | boolean flag (`-v`, `--verbose`); pass `""` to omit a form |
| `add_option(short, long, default="", help="", required=False)` | string option: `-o FILE`, `-oFILE`, `--output FILE`, `--output=FILE` |
| `add_choice_option(short, long, choices, default="", help="")` | string option restricted to `choices` |
| `add_int_option(short, long, default=0, help="", required=False)` | integer option |
| `add_float_option(short, long, default=0.0, help="", required=False)` | floating-point option |
| `add_multi_option(short, long, help="")` | repeatable option, collected in order |
| `add_positional(name, help="")` | required positional argument |
| `add_optional_positional(name, default="", help="")` | optional positional (after the required ones) |
| `add_rest(name, help="")` | all remaining positionals (zero or more); declare it last |
| `add_command(name, parser, help="")` | sub-command: when the first positional is `name`, the rest is parsed by `parser` |

## Parsing

`parser.parse(args)` returns a `Namespace` or raises `ArgumentError` with a message such as `unrecognized arguments: --bogus`, `argument -n/--count: invalid int value: 'x'` or `the following arguments are required: file`. Short flags can be combined (`-vq`), an attached value works (`-n5`), `--` ends option parsing, negative numbers are positionals, and `-h`/`--help` stops parsing and sets `help_requested`. Long option abbreviations are **not** accepted. Behaviour matches Python's `parse_intermixed_args` on the supported feature set (checked against Python by a randomised golden test).

| `Namespace` member | Meaning |
|---|---|
| `flag(name)` | value of a flag |
| `get_str(name)`, `get_int(name)`, `get_float(name)` | option or positional value (the default when not given) |
| `get_list(name)` | values of a multi option or `add_rest` |
| `has(name)` | `True` when the argument was given explicitly |
| `command` | the sub-command name, or `""` |
| `help_requested` | `True` when `-h` or `--help` was seen |

`parser.usage()` and `parser.help_text()` build the help text.

```nox
import nox.argparse
from nox.argparse import ArgumentParser, Namespace, ArgumentError

p: ArgumentParser = ArgumentParser("tool", "Copy files.")
p.add_flag("-v", "--verbose", "chatty output")
p.add_int_option("-n", "--count", 1, "repeat count")
p.add_positional("src", "source file")
p.add_optional_positional("dst", "out.txt", "destination")

ns: Namespace = p.parse(["-v", "-n", "3", "a.txt"])
print(ns.flag("verbose"), ns.get_int("count"), ns.get_str("src"), ns.get_str("dst"))
try:
    p.parse(["-n", "x", "a.txt"])
except ArgumentError as e:
    print(e)
print(p.usage())
```

```output
True 3 a.txt out.txt
argument -n/--count: invalid int value: 'x'
usage: tool [-h] [-v] [-n COUNT] src [dst]
```
