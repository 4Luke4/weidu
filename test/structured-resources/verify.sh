#!/bin/sh
set -eu

for expected in \
  s_equiv.itm l_equiv.itm life.itm itmv11.itm itmv20.itm \
  splv1.spl splv20.spl effv20.eff cgraph.itm \
  rbsource.spl rbresult.spl badlay.itm
do
  if [ ! -f "override/$expected" ]; then
    printf '%s\n' "missing generated fixture: override/$expected" >&2
    exit 1
  fi
done

test "$(wc -c < override/life.itm)" -eq 314
test "$(wc -c < override/splv1.spl)" -eq 250
test "$(wc -c < override/effv20.eff)" -eq 272
test "$(wc -c < override/cgraph.itm)" -eq 462
test "$(wc -c < override/rbsource.spl)" -eq 434
test "$(wc -c < override/rbresult.spl)" -eq 434

printf '%s\n' 'STRUCTURED_RESOURCE_FILES_OK'
