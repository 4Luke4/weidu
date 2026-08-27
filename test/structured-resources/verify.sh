#!/bin/sh
set -eu

for expected in \
  s_equiv.itm l_equiv.itm life.itm itmv11.itm itmv20.itm \
  splv1.spl splv20.spl effv20.eff badlay.itm
do
  if [ ! -f "override/$expected" ]; then
    printf '%s\n' "missing generated fixture: override/$expected" >&2
    exit 1
  fi
done

test "$(wc -c < override/life.itm)" -eq 314
test "$(wc -c < override/splv1.spl)" -eq 250
test "$(wc -c < override/effv20.eff)" -eq 272

printf '%s\n' 'STRUCTURED_RESOURCE_FILES_OK'
