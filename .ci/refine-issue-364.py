#!/usr/bin/env python3
from pathlib import Path

path = Path("src/tpaction.ml")
text = path.read_text(encoding="utf-8")
old = 'let filler_line = Str.regexp "^[0-9]+[ \\t]+\\*[ \\t]+\\*" in'
new = 'let filler_line = Str.regexp "^[0-9]+[ \\t]+[*][ \\t]+[*]" in'

occurrences = text.count(old)
if occurrences != 1:
    raise SystemExit(
        f"filler-row regex refinement: expected exactly one match, found {occurrences}"
    )

path.write_text(text.replace(old, new, 1), encoding="utf-8")
