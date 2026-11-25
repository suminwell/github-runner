"""Verify both architecture packages of the current platform in separate processes."""
import os
from pathlib import Path
import subprocess
import sys


if __name__ == '__main__':
    for arch in ('x64', 'arm64'):
        print('Testing %s package on %s' % (arch, sys.platform), flush=True)
        env = os.environ.copy()
        env['LOCAL_RUNNER_TEST_ARCH'] = arch
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s',
                        str(Path(__file__).resolve().parent), '-v'], env=env, check=True)
