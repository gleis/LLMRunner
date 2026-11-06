#!/usr/bin/env python3
"""Reject a release app that depends on unbundled third-party native libraries."""
from pathlib import Path
import subprocess
import sys


def check(app: Path) -> None:
    libraries = app / 'Contents/Resources/lib'
    count = 0
    for path in (app / 'Contents').rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
            continue
        count += 1
        output = subprocess.check_output(['otool', '-L', str(path)], text=True)
        for line in output.splitlines()[1:]:
            dependency = line.strip().split(' (compatibility version')[0]
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dependency.startswith('@rpath/') and (libraries / dependency.removeprefix('@rpath/')).exists():
                continue
            if dependency.startswith('@loader_path/') and (path.parent / dependency.removeprefix('@loader_path/')).exists():
                continue
            raise RuntimeError(f'Unbundled dependency in {path.name}: {dependency}')
    if count == 0:
        raise RuntimeError('No native executables found in release app')
    print(f'Checked {count} native release files: dependencies are bundled or provided by macOS')


if __name__ == '__main__':
    check(Path(sys.argv[1]))
