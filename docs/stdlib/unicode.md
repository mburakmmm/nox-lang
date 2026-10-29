# nox.unicode

Unicode normalization (UAX #15) and locale-specific case mapping for Turkish and Azeri. `str` itself already follows Unicode for
`upper()`, `lower()`, `casefold()` and the `is...()` tests (see [Strings](../language/strings.md#methods)); this module adds what a
string method cannot express.

```text
import nox.unicode
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `normalize(s, form="NFC")` | `s` in normalization form `"NFC"`, `"NFD"`, `"NFKC"` or `"NFKD"`; any other name raises `ValueError` |
| `is_normalized(s, form="NFC")` | whether `normalize(s, form)` leaves `s` unchanged |
| `upper_tr(s)` | `upper()` with the Turkish pairs `i`→`İ` and `ı`→`I` |
| `lower_tr(s)` | `lower()` with the Turkish pairs `I`→`ı` and `İ`→`i` |

The tables come from the same Unicode version as the `str` methods (17.0) and are checked against Python's `unicodedata`
(`scripts/gen_unicode_tables.py`). Invalid UTF-8 bytes pass through unchanged and never combine with their neighbours.

```nox
import nox.unicode

composed: str = nox.unicode.normalize("e\u0301", "NFC")
print(len(composed), composed == "\u00e9", nox.unicode.is_normalized("e\u0301"))
print(len(nox.unicode.normalize("\u00e9", "NFD")), nox.unicode.normalize("\ufb01", "NFKC"))
print(nox.unicode.upper_tr("istanbul"), nox.unicode.lower_tr("ISPARTA"), "istanbul".upper())
```

```output
1 True False
2 fi
İSTANBUL ısparta ISTANBUL
```

## Not covered

Text shaping (ligatures, Arabic joining, bidirectional ordering) and grapheme-cluster segmentation are rendering concerns and are not part
of the string library. `len(s)` counts code points, not user-perceived characters; normalize first when comparing text that may be
composed differently.
