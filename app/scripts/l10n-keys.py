#!/usr/bin/env python3
"""Lists every interface string (the English keys of L("…")) and checks each translation table.
Usage: scripts/l10n-keys.py            → report missing / unused keys per language
       scripts/l10n-keys.py --keys     → print all keys"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
string = r'"((?:[^"\\]|\\.)*)"'
keys = set()
for f in (root / "Sources/Strip").rglob("*.swift"):
    if "Localization" in f.parts:
        continue
    keys.update(re.findall(r'\bL\(' + string, f.read_text()))

if "--keys" in sys.argv:
    print("\n".join(sorted(keys)))
    sys.exit(0)

ok = True
for lang in ["tr", "es", "fr", "it"]:
    path = root / f"Sources/Strip/Localization/Localization+{lang}.swift"
    if not path.exists():
        print(f"{lang}: missing file"); ok = False; continue
    text = path.read_text()
    pairs = dict(re.findall(r'^\s*' + string + r'\s*:\s*' + string, text, re.M))
    table = set(pairs)
    missing, unused = keys - table, table - keys
    # Format placeholders must match the English text (positional %1$@ counts as %@).
    def specs(s): return sorted(re.sub(r'%\d\$', '%', m) for m in re.findall(r'%(?:\d\$)?[@d]', s))
    for k, v in pairs.items():
        if specs(k) != specs(v):
            print(f"   placeholders differ: {k!r} → {v!r}"); ok = False
    print(f"{lang}: {len(table)} entries, {len(missing)} missing, {len(unused)} unused")
    for k in sorted(missing): print(f"   missing: {k}")
    for k in sorted(unused): print(f"   unused:  {k}")
    ok = ok and not missing
sys.exit(0 if ok else 1)
