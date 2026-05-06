import re
import pathlib
import sys

target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path('/angr-dev')

for p in target.rglob('pyproject.toml'):
    original = p.read_text()
    # PEP 621 requires license as table {text=} or {file=}, not a bare SPDX string
    patched = re.sub(r'^license = "(.+)"$', r'license = {text = "\1"}', original, flags=re.MULTILINE)
    # license-files is PEP 639 and not supported by this setuptools version
    patched = re.sub(r'^license-files\s*=\s*\[.*?\]\n', '', patched, flags=re.MULTILINE | re.DOTALL)
    if patched != original:
        p.write_text(patched)
        print(f'patched: {p}')
    else:
        print(f'no change: {p}')
