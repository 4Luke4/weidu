#!/bin/sh
set -eu

for expected in \
  s_equiv.itm l_equiv.itm life.itm itmv11.itm itmv20.itm \
  splv1.spl splv20.spl effv20.eff complex_graph.itm \
  complex_rollback_source.spl complex_rollback.spl badlay.itm
do
  if [ ! -f "override/$expected" ]; then
    printf '%s\n' "missing generated fixture: override/$expected" >&2
    exit 1
  fi
done

test "$(wc -c < override/life.itm)" -eq 314
test "$(wc -c < override/splv1.spl)" -eq 250
test "$(wc -c < override/effv20.eff)" -eq 272
test "$(wc -c < override/complex_graph.itm)" -eq 462
test "$(wc -c < override/complex_rollback_source.spl)" -eq 434
test "$(wc -c < override/complex_rollback.spl)" -eq 434

printf '%s\n' 'STRUCTURED_RESOURCE_FILES_OK'
