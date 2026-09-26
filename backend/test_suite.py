"""고정 runner. 실제 사용자 저장소/인증 파일을 읽거나 복사하지 않는다."""
import argparse
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', required=True)
    p.add_argument('--artifacts-root', default=str(Path(os.environ['USERPROFILE']) / 'Documents' / 'CtxHopDesktopTests'))
    args = p.parse_args()
    root = Path(__file__).resolve().parent
    artifacts = Path(args.artifacts_root) / ('suite-' + uuid.uuid4().hex)
    artifacts.mkdir(parents=True)
    report = {'artifacts': str(artifacts), 'nativeExe': args.exe, 'runs': []}
    for label, extra in [('normal', []), ('unsafe-source-policy', ['--sandbox', 'danger-full-access', '--approval', 'never'])]:
        probe = subprocess.run([sys.executable, '-X', 'utf8', str(root / 'native_probe.py'), '--exe', args.exe,
            '--root', str(artifacts), *extra], capture_output=True, text=True, encoding='utf-8')
        (artifacts / (label + '-probe.log')).write_text(probe.stdout + probe.stderr, encoding='utf-8')
        if probe.returncode:
            report['runs'].append({'label': label, 'probeExit': probe.returncode, 'testExit': None})
            break
        home = json.loads(probe.stdout)['home']
        tests = subprocess.run([sys.executable, '-X', 'utf8', str(root / 'test_desktop_sessions.py'),
            '--fixture-home', home, '--exe', args.exe, '--artifacts', str(artifacts / label)],
            capture_output=True, text=True, encoding='utf-8')
        (artifacts / (label + '-tests.log')).write_text(tests.stdout + tests.stderr, encoding='utf-8')
        report['runs'].append({'label': label, 'probeExit': probe.returncode, 'testExit': tests.returncode, 'fixtureHome': home})
        if tests.returncode:
            break
    report['ok'] = len(report['runs']) == 2 and all(x['probeExit'] == 0 and x['testExit'] == 0 for x in report['runs'])
    (artifacts / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
