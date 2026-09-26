"""고정 native fixture와 임시 저장소만 변경하는 회귀 시험."""
import argparse
import copy
import io
import json
import shutil
import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

import desktop_sessions as d
from native_probe import Rpc

FIXTURE = None
EXE = None
ARTIFACTS = None


class Sessions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with d.ro(FIXTURE / d.FILES[0]) as db:
            cls.thread_id = db.execute('SELECT id FROM threads LIMIT 1').fetchone()[0]
        cls.full = d.selected(FIXTURE, cls.thread_id)
        cls.original = d.read_archive(FIXTURE / 'first.zip') if (FIXTURE / 'first.zip').exists() else cls.full

    def setUp(self):
        self.root = ARTIFACTS / ('unit-' + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.cwd = self.root / '새 작업 폴더 - 매우 긴 경로 테스트'
        self.cwd.mkdir()
        self.archive = self.root / 'source.zip'
        d.write_archive(self.original, self.archive)
        self.guard = lambda: None  # fixture-only 내부 엔진 시험. CLI에 우회 옵션 없음.

    def preview(self, archive=None):
        return d.inspect(self.home, archive or self.archive, self.cwd)

    def apply(self, archive=None, choice='incoming', failpoint=None):
        archive = archive or self.archive
        preview = self.preview(archive)
        return d.apply(self.home, archive, self.cwd, preview['token'], choice,
            guard=self.guard, failpoint=failpoint)

    def append(self, label):
        snapshot = copy.deepcopy(self.original)
        snapshot['rollout'] += d.encoded({'timestamp': '2026-09-26T08:00:00Z',
            'type': 'event_msg', 'payload': {'type': 'user_message', 'message': label}}) + b'\n'
        archive = self.root / (label + '.zip')
        d.write_archive(snapshot, archive)
        return archive

    def test_01_first_import_and_offsets(self):
        self.assertEqual(self.preview()['status'], 'new')
        result = self.apply()
        self.assertEqual(result['status'], 'imported')
        restored = d.selected(self.home, self.thread_id)
        self.assertEqual(d.canonical(restored['rollout'], self.thread_id), d.canonical(self.original['rollout'], self.thread_id))
        self.assertEqual(restored['data']['thread']['cwd'], str(self.cwd))
        self.assertEqual(restored['data']['thread']['sandbox_policy'], '{"type":"read-only"}')
        self.assertEqual(restored['data']['thread']['approval_mode'], 'untrusted')
        self.assertEqual(restored['data']['thread']['project_id'], None)
        delta = len(restored['rollout']) - len(self.original['rollout'])
        for left, right in zip(self.original['data']['history']['thread_turns'], restored['data']['history']['thread_turns']):
            for key in ('rollout_byte_offset', 'rollout_end_byte_offset'):
                if left[key] and left[key] > len(self.original['rollout'].split(b'\n')[0]):
                    if key == 'rollout_end_byte_offset':
                        self.assertEqual(right[key], left[key] + delta)
                    else:
                        header_delta = len(restored['rollout'].split(b'\n')[0]) - len(self.original['rollout'].split(b'\n')[0])
                        self.assertEqual(right[key], left[key] + header_delta)
        self.assertEqual(self.preview()['status'], 'equal')

    def test_02_native_read_resume(self):
        self.apply()
        rpc = Rpc(EXE, self.home)
        try:
            read = rpc.call('thread/read', {'threadId': self.thread_id, 'includeTurns': False})
            self.assertEqual(read['thread']['historyMode'], 'paginated')
            turns = rpc.call('thread/turns/list', {'threadId': self.thread_id, 'limit': 20, 'itemsView': 'full'})
            items = rpc.call('thread/items/list', {'threadId': self.thread_id, 'limit': 20})
            payload = json.dumps(items, ensure_ascii=False)
            self.assertIn('CTXHOP_NATIVE_FIXTURE_USER', payload)
            self.assertIn('CTXHOP_NATIVE_FIXTURE_REPLY', payload)
            resumed = rpc.call('thread/resume', {'threadId': self.thread_id, 'excludeTurns': True,
                'cwd': str(self.cwd), 'modelProvider': 'openai'})
            self.assertEqual(resumed['thread']['id'], self.thread_id)
            self.assertEqual(resumed['cwd'], str(self.cwd))
            self.assertEqual(resumed['sandbox']['type'], 'readOnly')
            self.assertEqual(resumed['approvalPolicy'], 'untrusted')
            (self.root / 'native-read-resume.json').write_text(json.dumps({'read': read,
                'turns': turns, 'items': items, 'resume': resumed}, ensure_ascii=False, indent=2), encoding='utf-8')
        finally:
            rpc.close()

    def test_03_latest_and_local_preferences(self):
        self.apply()
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('UPDATE threads SET is_pinned=1, sandbox_policy=?, approval_mode=? WHERE id=?',
                ('{"type":"workspace-write"}', 'on-request', self.thread_id))
        newer = self.append('later')
        self.assertEqual(self.preview(newer)['status'], 'incoming_newer')
        result = self.apply(newer)
        self.assertTrue(result['replaced'])
        self.assertTrue((Path(result['recovery']) / 'before.zip').exists())
        row = d.selected(self.home, self.thread_id)['data']['thread']
        self.assertEqual(row['is_pinned'], 1)
        self.assertEqual(row['approval_mode'], 'on-request')
        self.assertEqual(self.preview()['status'], 'local_newer')
        self.assertEqual(self.apply()['status'], 'local_newer')

    def test_04_divergent_choice_and_multiple(self):
        first, second = self.append('branchA'), self.append('branchB')
        self.apply(first)
        preview = self.preview(second)
        self.assertEqual(preview['status'], 'conflict')
        self.assertEqual(self.apply(second, choice='skip')['status'], 'skipped')
        self.assertEqual(self.preview(second)['status'], 'conflict')
        result = self.apply(second)
        self.assertTrue(result['replaced'])
        self.assertEqual(self.preview(second)['status'], 'equal')

    def test_05_stale_preview(self):
        preview = self.preview()
        self.apply()
        with self.assertRaisesRegex(ValueError, '바뀌었습니다'):
            d.apply(self.home, self.archive, self.cwd, preview['token'], 'incoming', guard=self.guard)

    def test_06_guard_before_any_write(self):
        preview = self.preview()
        def blocked():
            raise ValueError('fixture writer')
        with self.assertRaisesRegex(ValueError, 'writer'):
            d.apply(self.home, self.archive, self.cwd, preview['token'], 'incoming', guard=blocked)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_07_schema_and_untrusted_columns(self):
        d.create_database(self.home / d.FILES[0], d.FILES[0])
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('CREATE TABLE injected(x)')
        with self.assertRaisesRegex(ValueError, '구조'):
            self.preview()
        bad = copy.deepcopy(self.original)
        bad['data']['thread']['id); DROP TABLE threads; --'] = 1
        badfile = self.root / 'bad.zip'
        d.write_archive(bad, badfile)
        with self.assertRaisesRegex(ValueError, '열 목록'):
            d.read_archive(badfile)

    def test_08_wrong_id_and_missing_newline(self):
        bad = copy.deepcopy(self.original)
        bad['data']['thread']['id'] = str(uuid.uuid4())
        with self.assertRaisesRegex(ValueError, 'ID'):
            d.validate(bad)
        bad = copy.deepcopy(self.original)
        bad['rollout'] = bad['rollout'].rstrip(b'\n')
        with self.assertRaisesRegex(ValueError, '불완전'):
            d.validate(bad)

    def test_09_outside_path_and_zip_duplicates(self):
        with self.assertRaises(ValueError):
            d.rollout_path(self.home, self.home / 'sessions' / '..' / '..' / 'outside.jsonl')
        import zipfile
        bad = self.root / 'duplicate.zip'
        with zipfile.ZipFile(bad, 'w') as archive:
            archive.writestr('manifest.json', '{}')
            archive.writestr('manifest.json', '{}')
        with self.assertRaisesRegex(ValueError, '항목'):
            d.read_archive(bad)

    def test_10_recovery_first_import(self):
        def fail(stage):
            raise RuntimeError('injected ' + stage)
        with self.assertRaisesRegex(RuntimeError, 'injected'):
            self.apply(failpoint=fail)
        runs = d.pending(self.home)
        self.assertEqual(len(runs), 1)
        with self.assertRaisesRegex(ValueError, '복구'):
            self.apply()
        result = d.recover(self.home, runs[0].parent, guard=self.guard)
        self.assertEqual(result['status'], 'rolled_back')
        self.assertIsNone(d.selected(self.home, self.thread_id))
        self.assertEqual(d.pending(self.home), [])

    def test_11_recovery_update_after_commit(self):
        self.apply()
        before = d.selected(self.home, self.thread_id)
        def fail(stage):
            if stage == 'commit':
                raise RuntimeError('injected commit')
        with self.assertRaisesRegex(RuntimeError, 'commit'):
            self.apply(self.append('after'), failpoint=fail)
        run = d.pending(self.home)[0].parent
        d.recover(self.home, run, guard=self.guard)
        self.assertEqual(d.snapshot_hash(d.selected(self.home, self.thread_id)), d.snapshot_hash(before))

    def test_12_recovery_refuses_post_failure_edits(self):
        def fail(stage):
            raise RuntimeError('injected')
        with self.assertRaises(RuntimeError):
            self.apply(failpoint=fail)
        run = d.pending(self.home)[0].parent
        journal = json.loads((run / 'journal.json').read_text(encoding='utf-8'))
        Path(journal['path']).write_bytes(b'new user changes\n')
        with self.assertRaisesRegex(ValueError, '파일이 변경'):
            d.recover(self.home, run, guard=self.guard)

    def test_13_page_search_all_projects(self):
        self.apply()
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            row = d.selected(self.home, self.thread_id)['data']['thread']
            for index in range(5000):
                item = {**row, 'id': str(uuid.uuid4()), 'title': f'fixture {index}', 'cwd': f'C:\\project{index%10}', 'archived': index%2}
                columns = list(item)
                db.execute(f'INSERT INTO threads ({",".join(columns)}) VALUES ({",".join("?" for x in columns)})', list(item.values()))
        page = d.list_sessions(self.home, limit=200, offset=200)
        self.assertEqual(page['total'], 5001)
        self.assertEqual(len(page['sessions']), 200)
        self.assertEqual(d.list_sessions(self.home, search='fixture 4999')['total'], 1)
        self.assertEqual(d.list_sessions(self.home, search='%')['total'], 0)

    def test_14_multiple_anomalies_defaults(self):
        self.apply(self.append('local-branch'))
        invalid = self.root / 'invalid.zip'
        invalid.write_bytes(b'invalid')
        jobs = [{'key': 'conflict-one', 'archive': str(self.append('other-branch')), 'cwd': str(self.cwd)},
            {'key': 'broken-two', 'archive': str(invalid), 'cwd': str(self.cwd)},
            {'key': 'missing-three', 'archive': str(self.root / 'missing.zip'), 'cwd': str(self.cwd)}]
        result = d.inspect_many(self.home, jobs)['items']
        self.assertEqual([x['status'] for x in result], ['conflict', 'blocked', 'blocked'])
        self.assertEqual([x['choice'] for x in result], ['skip'] * 3)
        self.assertIsNone(result[1]['token'])
        self.assertEqual([x['key'] for x in result], [x['key'] for x in jobs])

    def test_15_null_required_and_runtime_version(self):
        bad = copy.deepcopy(self.original)
        bad['data']['thread']['title'] = None
        with self.assertRaisesRegex(ValueError, '필수'):
            d.validate(bad)
        bad = copy.deepcopy(self.original)
        bad['manifest']['engineVersion'] = 'unknown'
        with self.assertRaisesRegex(ValueError, '버전'):
            d.validate(bad)

    def test_16_guard_again_before_commit(self):
        calls = []
        def guard():
            calls.append(1)
            if len(calls) == 2:
                raise ValueError('fixture writer appeared')
        preview = self.preview()
        with self.assertRaisesRegex(ValueError, 'appeared'):
            d.apply(self.home, self.archive, self.cwd, preview['token'], 'incoming', guard=guard)
        self.assertIsNone(d.selected(self.home, self.thread_id))
        run = d.pending(self.home)[0].parent
        d.recover(self.home, run, guard=self.guard)
        self.assertEqual(d.pending(self.home), [])

    def test_17_actual_native_extension(self):
        if d.canonical(self.full['rollout'], self.thread_id) == d.canonical(self.original['rollout'], self.thread_id):
            self.skipTest('2-turn native fixture required')
        self.apply()
        archive = self.root / 'actual-native-latest.zip'
        d.write_archive(self.full, archive)
        self.assertEqual(self.preview(archive)['status'], 'incoming_newer')
        self.apply(archive)
        rpc = Rpc(EXE, self.home)
        try:
            turns = rpc.call('thread/turns/list', {'threadId': self.thread_id, 'limit': 20, 'itemsView': 'full'})
            self.assertEqual(len(turns['data']), 2)
            self.assertIn('CTXHOP_NATIVE_FIXTURE_USER_SECOND', json.dumps(turns))
        finally:
            rpc.close()

    def run_cli(self, *argv):
        # 실제 CLI 분기(main)를 실행한다. writer 검사만 고정값으로 바꾼다.
        out = io.TextIOWrapper(io.BytesIO(), encoding='utf-8')
        with mock.patch.object(sys, 'argv', ['desktop_sessions.py', *argv]), mock.patch.object(sys, 'stdout', out):
            code = d.main()
            out.flush()
            return code, json.loads(out.buffer.getvalue().decode('utf-8'))

    def test_19_cli_contract_for_gui(self):
        output = self.root / 'exported.zip'
        with mock.patch.object(d, 'assert_closed', return_value='0.158.0-alpha.2.1'):
            code, result = self.run_cli('export', '--home', str(FIXTURE), '--id', self.thread_id, '--output', str(output))
        self.assertEqual(code, 0)
        self.assertEqual(set(result['metadata']), {'sessionId', 'title', 'sourceCwd', 'updatedAt', 'historyMode', 'cliVersion', 'recordCount'})
        self.assertEqual(result['metadata']['cliVersion'], '0.158.0-alpha.2.1')
        self.assertRegex(result['metadata']['updatedAt'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertEqual(d.read_archive(output)['manifest']['engineVersion'], '0.158.0-alpha.2.1')
        code, page = self.run_cli('list', '--home', str(FIXTURE), '--search', self.thread_id[:8])
        self.assertEqual((code, page['total']), (0, 1))
        self.assertIs(type(page['sessions'][0]['archived']), bool)
        self.assertIs(page['sessions'][0]['subagent'], False)
        self.assertRegex(page['sessions'][0]['updatedAt'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        # 실제 writer 검사(앱 실행 중) 또는 잘못된 token 중 먼저 걸리는 쪽에서 쓰기 전에 차단돼야 한다.
        code, blocked = self.run_cli('apply', '--home', str(self.home), '--archive', str(self.archive),
            '--cwd', str(self.cwd), '--token', 'x', '--choice', 'incoming')
        self.assertEqual((code, blocked['status'], blocked['pending']), (1, 'blocked', []))
        self.assertTrue(blocked['reason'])
        self.assertEqual(list(self.home.iterdir()), [])

    def test_20_multiline_title_and_engine_match(self):
        self.apply()
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('UPDATE threads SET title=?, name=? WHERE id=?', ('첫 줄\r\n둘째 줄\x00끝',) * 2 + (self.thread_id,))
        output = self.root / 'multiline.zip'
        with mock.patch.object(d, 'assert_closed', return_value=d.VERSIONS[-1]):
            code, result = self.run_cli('export', '--home', str(self.home), '--id', self.thread_id, '--output', str(output))
        self.assertEqual(code, 0)
        self.assertNotRegex(result['metadata']['title'], '[\x00\r\n]')
        self.assertIn('둘째 줄', result['metadata']['title'])
        other = self.root / 'receiver'
        other.mkdir()
        token = d.inspect(other, self.archive, self.cwd)['token']
        with self.assertRaisesRegex(ValueError, '엔진'):
            d.apply(other, self.archive, self.cwd, token, 'incoming', guard=lambda: d.VERSIONS[0])
        self.assertEqual(list(other.iterdir()), [])
        self.assertEqual(d.apply(other, self.archive, self.cwd, token, 'incoming',
            guard=lambda: d.read_archive(self.archive)['manifest']['engineVersion'])['status'], 'imported')

    def test_21_stale_journal_temp_is_replaced(self):
        def fail(stage):
            raise RuntimeError('injected')
        with self.assertRaises(RuntimeError):
            self.apply(failpoint=fail)
        run = d.pending(self.home)[0].parent
        (run / 'journal.tmp').write_bytes(b'left by an interrupted write')
        self.assertEqual(d.recover(self.home, run, guard=self.guard)['status'], 'rolled_back')
        self.assertEqual(d.pending(self.home), [])

    def test_22_preview_blocks_engine_mismatch_and_marks_subagents(self):
        stamped = d.read_archive(self.archive)['manifest']['engineVersion']
        other = next(v for v in d.VERSIONS if v != stamped)
        with mock.patch.object(d, 'engine_version', return_value=other):
            code, blocked = self.run_cli('inspect', '--home', str(self.home), '--archive', str(self.archive), '--cwd', str(self.cwd))
        self.assertEqual((code, blocked['status']), (1, 'blocked'))
        self.assertIn('엔진', blocked['reason'])
        with mock.patch.object(d, 'engine_version', return_value=stamped):
            code, preview = self.run_cli('inspect', '--home', str(self.home), '--archive', str(self.archive), '--cwd', str(self.cwd))
        self.assertEqual((code, preview['status']), (0, 'new'))
        self.apply()
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('UPDATE threads SET source=? WHERE id=?', ('{"subagent":{"other":"guardian"}}', self.thread_id))
        self.assertIs(d.list_sessions(self.home)['sessions'][0]['subagent'], True)
        self.assertRegex(d.CLOSED_CHECK, r'\|ChatGPT\|')

    def test_23_conflict_restore_local_branch_revivable_from_before_zip(self):
        # README 수동 절차: 복원 전 로컬 갈래(before.zip)를 inspect → apply로 되살린다.
        local, shared = self.append('localBranch'), self.append('sharedBranch')
        self.apply(local)
        run = Path(self.apply(shared)['recovery'])
        before = run / 'before.zip'
        stamped = d.read_archive(before)['manifest']['engineVersion']
        args = ('--home', str(self.home), '--archive', str(before), '--cwd', str(self.cwd))
        with mock.patch.object(d, 'engine_version', return_value=stamped), \
                mock.patch.object(d, 'assert_closed', return_value=stamped):
            code, preview = self.run_cli('inspect', *args)
            self.assertEqual((code, preview['status']), (0, 'conflict'))
            code, done = self.run_cli('apply', *args, '--token', preview['token'], '--choice', 'incoming')
        self.assertEqual((code, done['status']), (0, 'imported'))
        self.assertEqual(self.preview(local)['status'], 'equal')
        self.assertTrue((Path(done['recovery']) / 'before.zip').exists())

    def test_24_before_zip_records_this_pc_engine(self):
        # 목록의 최신 버전이 아니라 guard가 돌려준 이 PC 엔진을 기록해야 alpha.2 PC에서도 되살릴 수 있다.
        old = d.VERSIONS[0]
        def stamped(label):
            snapshot = d.read_archive(self.append(label))
            snapshot['manifest']['engineVersion'] = old
            archive = self.root / (label + '-old.zip')
            d.write_archive(snapshot, archive)
            return archive
        for archive in (stamped('localBranch'), stamped('sharedBranch')):
            result = d.apply(self.home, archive, self.cwd, self.preview(archive)['token'], 'incoming', guard=lambda: old)
        before = Path(result['recovery']) / 'before.zip'
        self.assertEqual(d.read_archive(before)['manifest']['engineVersion'], old)
        self.assertEqual(d.inspect(self.home, before, self.cwd, old)['status'], 'conflict')

    def test_25_recover_checks_writers_and_schema_not_engine_list(self):
        def fail(stage):
            raise RuntimeError('injected')
        writers = mock.patch.object(d, 'assert_no_writers', return_value=None)
        unsupported = mock.patch.object(d, 'engine_version', side_effect=ValueError('unsupported engine'))
        with self.assertRaises(RuntimeError):
            self.apply(failpoint=fail)
        run = d.pending(self.home)[0].parent
        with writers as checked, unsupported:
            self.assertEqual(d.recover(self.home, run)['status'], 'rolled_back')
        self.assertGreaterEqual(checked.call_count, 2)
        self.assertIsNone(d.selected(self.home, self.thread_id))
        # 엔진 업데이트가 DB 구조까지 바꿨다면 복구는 쓰기 전에 멈춘다.
        with self.assertRaises(RuntimeError):
            self.apply(failpoint=fail)
        run = d.pending(self.home)[0].parent
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('CREATE TABLE schema_drift (x)')
        with writers, unsupported, self.assertRaisesRegex(ValueError, 'DB 구조'):
            d.recover(self.home, run)
        self.assertEqual(len(d.pending(self.home)), 1)

    def test_26_recover_rechecks_schema_inside_write_lock(self):
        def fail(stage):
            raise RuntimeError('injected')
        with self.assertRaises(RuntimeError):
            self.apply(failpoint=fail)
        run = d.pending(self.home)[0].parent
        real, calls = d.check_schema, []
        def drift_after_first_check(home, allow_missing=False):
            calls.append(allow_missing)
            real(home, allow_missing)
            if len(calls) == 1:
                # 첫 검사(잠금 전)와 쓰기 잠금 사이에 앱이 구조를 바꾼 상황
                with sqlite3.connect(self.home / d.FILES[0]) as db:
                    db.execute('CREATE TABLE schema_drift (x)')
        with mock.patch.object(d, 'check_schema', drift_after_first_check), \
                self.assertRaisesRegex(ValueError, 'DB 구조'):
            d.recover(self.home, run, guard=self.guard)
        self.assertEqual(calls, [True, False])
        self.assertEqual(len(d.pending(self.home)), 1)

    def test_18_archive_change_before_commit(self):
        preview = self.preview()
        replacement = self.append('different-input').read_bytes()
        calls = []
        def guard():
            calls.append(1)
            if len(calls) == 2:
                self.archive.write_bytes(replacement)
        with self.assertRaisesRegex(ValueError, '바뀌었습니다'):
            d.apply(self.home, self.archive, self.cwd, preview['token'], 'incoming', guard=guard)
        self.assertIsNone(d.selected(self.home, self.thread_id))
        run = d.pending(self.home)[0].parent
        d.recover(self.home, run, guard=self.guard)
        self.assertEqual(d.pending(self.home), [])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture-home', required=True)
    parser.add_argument('--exe', required=True)
    parser.add_argument('--artifacts', required=True)
    args = parser.parse_args()
    FIXTURE, EXE, ARTIFACTS = Path(args.fixture_home).resolve(), args.exe, Path(args.artifacts).resolve()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Sessions)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
