# 1. Hello, Nox

## Run a file

Create `hello.nox`:

```nox
print("Hello, Nox!")
```

```output
Hello, Nox!
```

Run it:

```sh
noxc run hello.nox
```

`noxc` type-checks the file, compiles it to a native executable, and runs it. The statements at the top level of the file *are* the program —
there is no `main` function to write.

## Build an executable

```sh
noxc build -o hello hello.nox
./hello
```

`noxc build` produces a standalone binary with the Nox runtime linked in. It starts instantly, has no dependencies on a Nox installation,
and can be copied to another machine of the same platform.

## Check without compiling

```sh
noxc check hello.nox
```

`check` runs only the front end (parsing and type checking), so it is the fastest way to see errors while you edit.

## Start a project

```sh
noxc init demo
cd demo
noxc run main.nox
```

`noxc init` creates a directory with a `nox.json` manifest and a `main.nox`. A project is what you need once you have more than one file or want
to use third-party packages (chapter 8).

## Comments and layout

Nox uses Python's layout: blocks are indented (with spaces), `#` starts a comment, and one statement goes on each line.

```nox
# a comment
total: int = 1 + 2   # a trailing comment
print(total)
```

```output
3
```

## A taste of what is different

Unlike Python, every variable has a **type**, written after the name when it is first created. The compiler checks types before the program
runs — a misspelled name or a `str` where an `int` is expected is reported immediately, not discovered in production.

```nox
price: int = 20
tax: int = price // 5
print(price + tax)
```

```output
24
```

The next chapter explains the types.
