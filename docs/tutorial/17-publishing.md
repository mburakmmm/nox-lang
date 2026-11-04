# 17. Publishing a package

A Nox package is just a Git repository with a `nox.json`. There is no build server and no upload step: the **noxpkg** registry keeps a small index — name,
repository, description, tags — and `noxc` fetches the code straight from your repository. Sharing something takes five minutes.

## 1. Make it a package

Create a project and give it something worth importing. Here is a tiny library, `textkit`, with one useful function:

```sh
noxc init textkit
cd textkit
```

```nox-fragment
# textkit.nox
def title_case(text: str) -> str:
    words: list[str] = text.split(" ")
    out: list[str] = []
    for w in words:
        if len(w) > 0:
            out.append(w[0].upper() + w[1:].lower())
    return " ".join(out)
```

Package code is imported by the **alias** its users choose, followed by the module name: after `noxc add textkit`, a user writes `import textkit.textkit`
(alias `textkit`, module `textkit`). Keep one module per file and give the public ones clear names.

Edit `nox.json` so the metadata is honest:

```json
{
  "name": "textkit",
  "version": "0.1.0",
  "entry": "main.nox"
}
```

## 2. Test it

A library with no tests is a promise without evidence. Add `textkit_test.nox` as in [chapter 12](12-testing.md) and run:

```sh
noxc test
```

## 3. Push it to Git

```sh
git init && git add -A && git commit -m "textkit 0.1.0"
git tag v0.1.0
git remote add origin git@github.com:you/textkit.git
git push origin main --tags
```

Tags are how your users will pin a version: `noxc add textkit --ref v0.1.0`. Pick a tag for every release you want people to be able to rely on.

## 4. Sign in and publish

You need an account on the registry, and it uses your GitHub identity — no new password. Sign in once:

```sh
noxc login
```

`noxc` shows a short code, opens GitHub's device page in your browser and waits while you approve. The registry sees only your public GitHub profile, and your
GitHub credentials never reach `noxc`. A token for the registry is saved in `~/.nox/credentials`, readable only by you.

Then announce the package:

```sh
noxc publish github.com/you/textkit --ref v0.1.0 --description "Small text helpers" --tags text,strings
```

```text
submitted: textkit (id=…) as @you — awaiting approval
```

## What happens next

- The **name belongs to you** from this moment — nobody else can publish `textkit`.
- A new package is **reviewed by an administrator** before it appears in the index. Approval means "the metadata looks legitimate", not "the code is safe".
- When you publish a new version of a package you already own — same name, same repository — it goes **live straight away**; you see `published` instead of
  `submitted`. Sending the same submission twice never creates a second queue entry.
- Moving the package to a different repository goes through review again.

Once it is listed, anyone can find and add it:

```sh
noxc search text
noxc add textkit
```

## Good citizenship

- **Pin and lock.** Users pin your tags; you pin yours. Commit `nox.lock`.
- **Say what your code can do.** If it uses `extern def`, spawns processes or touches the network, say so in the description — a dependency runs with the full
  authority of the program that imports it ([Security](../reference/security.md)).
- **Keep the API small and the changes honest.** Follow semantic versioning — a breaking change gets a new major version ([Nox's own policy](../reference/versioning.md) is a good model).
- **Sign your commits** if you can; dependants can then require it with `"require_signed_commit": true`.

Full details are in [Packages and dependencies](../tools/packages.md) and [noxpkg](../tools/noxpkg.md).

Next: [18. Next steps](18-next-steps.md).
