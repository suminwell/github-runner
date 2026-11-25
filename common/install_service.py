#!/usr/bin/env python3
"""Install a system boot service running as the invoking Unix user."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import pwd
import subprocess
import tempfile


def unit_quote(value):
    if any(char in str(value) for char in '\n\r\x00'):
        raise ValueError("Newlines are not allowed in service paths")
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'


def linux_unit(root, user, home, path):
    return '\n'.join([
        '[Unit]', 'Description=GitHub organization runner supervisor',
        'Wants=network-online.target', 'After=network-online.target', 'StartLimitIntervalSec=0',
        '', '[Service]', 'Type=simple', 'User=' + user,
        'WorkingDirectory=' + unit_quote(root),
        'Environment=' + unit_quote('HOME=' + home), 'Environment=' + unit_quote('PATH=' + path),
        'ExecStart=' + unit_quote(root / 'bin/service.sh'),
        'Restart=always', 'RestartSec=10', 'KillMode=control-group', 'TimeoutStopSec=90',
        'UMask=0077', '', '[Install]', 'WantedBy=multi-user.target', ''
    ])


def macos_plist(root, user, home, path, label):
    return {
        'Label': label, 'UserName': user,
        'ProgramArguments': [str(root / 'bin/service.sh')],
        'WorkingDirectory': str(root), 'RunAtLoad': True, 'KeepAlive': True,
        'ThrottleInterval': 10, 'ExitTimeOut': 90, 'AbandonProcessGroup': False,
        'EnvironmentVariables': {'HOME': home, 'PATH': path},
        'StandardOutPath': '/dev/null', 'StandardErrorPath': str(root / 'logs/launchd.log'),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve()
    settings = json.loads((root / '.state/settings.json').read_text())
    account = pwd.getpwuid(os.getuid())
    if account.pw_uid == 0:
        raise SystemExit('Run the installer as a normal user')
    path = os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin')
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / 'service'
        if settings['platform'] == 'linux':
            if not Path('/run/systemd/system').is_dir():
                raise SystemExit('A Linux host booted with systemd is required (enable systemd for WSL)')
            name = 'local-github-runner-%s.service' % account.pw_uid
            source.write_text(linux_unit(root, account.pw_name, account.pw_dir, path))
            subprocess.run(['sudo', 'install', '-m', '644', str(source), '/etc/systemd/system/' + name], check=True)
            subprocess.run(['sudo', 'systemctl', 'daemon-reload'], check=True)
            subprocess.run(['sudo', 'systemctl', 'enable', name], check=True)
            subprocess.run(['sudo', 'systemctl', 'restart', name], check=True)
            subprocess.run(['sudo', 'systemctl', 'is-active', '--quiet', name], check=True)
        else:
            name = 'com.suminwell.github-runner.%s' % account.pw_uid
            target = '/Library/LaunchDaemons/' + name + '.plist'
            source.write_bytes(plistlib.dumps(macos_plist(root, account.pw_name, account.pw_dir, path, name)))
            subprocess.run(['sudo', 'launchctl', 'bootout', 'system/' + name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['sudo', 'install', '-o', 'root', '-g', 'wheel', '-m', '644', str(source), target], check=True)
            subprocess.run(['sudo', 'launchctl', 'enable', 'system/' + name], check=True)
            subprocess.run(['sudo', 'launchctl', 'bootstrap', 'system', target], check=True)
            subprocess.run(['sudo', 'launchctl', 'print', 'system/' + name], stdout=subprocess.DEVNULL, check=True)
        print('Boot service installed: ' + name)


if __name__ == '__main__':
    main()
