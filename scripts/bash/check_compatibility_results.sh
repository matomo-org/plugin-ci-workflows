#!/bin/bash

# Fails unless a PHPUnit JUnit log shows GeneratedAssetCompilationTest ran and
# GeneratedTwigCompilationTest ran or was skipped. github-action-tests fails a run in which PHPUnit
# executed nothing, but not one in which only one of the two classes was collected, which would
# leave the other check silently absent.
#
# Usage: check_compatibility_results.sh <junit.xml> <PluginName>

set -euo pipefail

python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    tree = ET.parse(sys.argv[1])
except (FileNotFoundError, ET.ParseError) as e:
    print(f"::error::Could not read the PHPUnit JUnit log {sys.argv[1]}: {e}")
    sys.exit(1)

# Only the generated classes count, not a same-named class in some other namespace.
generated = {
    f'Piwik\\Plugins\\{sys.argv[2]}\\{root}\\Integration\\{cls}': cls
    for root in ('tests', 'Test')
    for cls in ('GeneratedAssetCompilationTest', 'GeneratedTwigCompilationTest')
}
cases = {}
for case in tree.iter('testcase'):
    name = (case.get('class') or case.get('classname') or '').replace('.', '\\')
    if name not in generated:
        continue
    cls = generated[name]
    cases.setdefault(cls, []).append('skipped' if case.find('skipped') is not None else 'ran')

missing = False
for cls, may_skip in (('GeneratedAssetCompilationTest', False), ('GeneratedTwigCompilationTest', True)):
    outcomes = cases.get(cls, [])
    if not outcomes or (not may_skip and 'ran' not in outcomes):
        print(f"::error::{cls} did not run ({outcomes or 'not collected'}).")
        missing = True
    else:
        print(f"{cls}: {', '.join(outcomes)}")

sys.exit(1 if missing else 0)
PY
