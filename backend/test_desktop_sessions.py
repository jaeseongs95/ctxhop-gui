"""고정 native fixture와 임시 저장소만 변경하는 회귀 시험."""
import argparse
import copy
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
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

    def apply(self, archive=None, choice='incoming', failpoint=None, run_name=None):
        archive = archive or self.archive
        preview = self.preview(archive)
        return d.apply(self.home, archive, self.cwd, preview['token'], choice,
            guard=self.guard, failpoint=failpoint, run_name=run_name)

    def grown(self, family, index, label):
        """묶음의 index번 대화 세션 파일 끝에 기록 하나를 더한 사본."""
        family = copy.deepcopy(family)
        family['members'][index]['rollout'] += d.encoded({'timestamp': '2026-09-26T08:00:00Z',
            'type': 'event_msg', 'payload': {'type': 'user_message', 'message': label}}) + b'\n'
        return family

    def save(self, family, label):
        archive = self.root / (label + '.zip')
        d.write_archive(family, archive)
        return archive

    def append(self, label):
        return self.save(self.grown(self.original, 0, label), label)

    def rekeyed(self, item, thread_id, row_source, **header_fields):
        """대화 하나를 thread_id로 복사한다. 세션 헤더를 고치고 이력 행의 thread_id와 파일 위치를 맞춘다."""
        item = copy.deepcopy(item)
        item['data']['thread'].update(id=thread_id, source=row_source)
        first, rest = item['rollout'].split(b'\n', 1)
        header = json.loads(first)
        header['payload'].update(id=thread_id, **header_fields)
        new_first = json.dumps(header, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        item['rollout'] = new_first + b'\n' + rest
        for rows in item['data']['history'].values():
            for entry in rows:
                entry['thread_id'] = thread_id
                for key in ('rollout_byte_offset', 'rollout_end_byte_offset', 'next_rollout_byte_offset'):
                    if entry.get(key):
                        self.assertGreater(entry[key], len(first))
                        entry[key] += len(new_first) - len(first)
        return item

    def child(self, parent_id, root_id, label):
        """fixture 대화를 복사해 만든 하위 에이전트 대화(새 ID, subagent source, 헤더 parent_thread_id·session_id)."""
        spawn = {'parent_thread_id': parent_id, 'depth': 1, 'agent_nickname': label, 'agent_role': 'worker', 'agent_path': None}
        item = self.rekeyed(self.original['members'][0], str(uuid.uuid4()),
            json.dumps({'subagent': {'thread_spawn': spawn}}, separators=(',', ':')),
            session_id=root_id, parent_thread_id=parent_id, source={'subagent': {'thread_spawn': spawn}})
        item['data']['thread'].update(title=label, agent_nickname=label, agent_role='worker')
        return item

    def family(self, parents, base=None, status='open'):
        """base(기본 fixture)에 하위 대화를 붙인다. parents: 새 하위 대화마다 부모의 묶음 안 번호(0 = 최상위)."""
        family = copy.deepcopy(base or self.original)
        root_id = family['members'][0]['data']['thread']['id']
        for number, index in enumerate(parents):
            parent_id = family['members'][index]['data']['thread']['id']
            item = self.child(parent_id, root_id, f'agent-{len(family["members"])}')
            family['members'].append(item)
            family['edges'].append({'parent_thread_id': parent_id, 'child_thread_id': item['data']['thread']['id'], 'status': status})
        d.validate_family(family)
        return family

    def ids(self, family):
        return [item['data']['thread']['id'] for item in family['members']]

    def edges(self):
        with d.ro(self.home / d.FILES[0]) as db:
            return sorted(tuple(row) for row in db.execute('SELECT parent_thread_id,child_thread_id,status FROM thread_spawn_edges'))

    def test_01_first_import_and_offsets(self):
        self.assertEqual(self.preview()['status'], 'new')
        result = self.apply()
        self.assertEqual(result['status'], 'imported')
        restored = d.selected(self.home, self.thread_id)['members'][0]
        original = self.original['members'][0]
        self.assertEqual(d.canonical(restored['rollout'], self.thread_id), d.canonical(original['rollout'], self.thread_id))
        self.assertEqual(restored['data']['thread']['cwd'], str(self.cwd))
        self.assertEqual(restored['data']['thread']['sandbox_policy'], '{"type":"read-only"}')
        self.assertEqual(restored['data']['thread']['approval_mode'], 'untrusted')
        self.assertEqual(restored['data']['thread']['project_id'], None)
        def place(raw, at):  # (줄 번호, 줄 안 위치)
            return raw[:at].count(b'\n'), at - (raw.rfind(b'\n', 0, at) + 1)
        for left, right in zip(original['data']['history']['thread_turns'], restored['data']['history']['thread_turns']):
            for key in ('rollout_byte_offset', 'rollout_end_byte_offset'):
                if left[key]:
                    # 바뀐 설정 기록 길이만큼 옮겨져 두 파일에서 같은 줄의 같은 자리를 가리켜야 한다.
                    self.assertEqual(place(restored['rollout'], right[key]), place(original['rollout'], left[key]))
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
            # 작업 폴더를 넘기지 않아도(요청 값 없음) 원래 PC 폴더가 아니라 가져온 작업 폴더로 열린다.
            bare = rpc.call('thread/resume', {'threadId': self.thread_id, 'excludeTurns': True, 'modelProvider': 'openai'})
            self.assertEqual((bare['cwd'], bare['approvalPolicy'], bare['sandbox']['type']), (str(self.cwd), 'untrusted', 'readOnly'))
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
        row = d.selected(self.home, self.thread_id)['members'][0]['data']['thread']
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
        bad['members'][0]['data']['thread']['id); DROP TABLE threads; --'] = 1
        badfile = self.root / 'bad.zip'
        d.write_archive(bad, badfile)
        with self.assertRaisesRegex(ValueError, '열 목록'):
            d.read_archive(badfile)

    def test_08_wrong_id_and_missing_newline(self):
        bad = copy.deepcopy(self.original)
        bad['members'][0]['data']['thread']['id'] = str(uuid.uuid4())
        with self.assertRaisesRegex(ValueError, 'ID'):
            d.validate_family(bad)
        bad = copy.deepcopy(self.original)
        bad['members'][0]['rollout'] = bad['members'][0]['rollout'].rstrip(b'\n')
        with self.assertRaisesRegex(ValueError, '불완전'):
            d.validate_family(bad)

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

    def test_10b_recovery_named_by_caller(self):
        # 부르는 쪽의 작업 ID가 복구 기록 폴더 이름이 된다. 형식이 틀리면 아무것도 쓰기 전에, 같은 이름이 있으면 쓰기 전에 거부한다.
        with self.assertRaisesRegex(ValueError, '작업 이름'):
            self.apply(run_name='../escape')
        self.assertFalse((self.home / '.ctxhop-desktop-recovery').exists())
        self.assertFalse((self.home / d.FILES[0]).exists())
        name = 'ab' * 16
        def fail(stage):
            raise RuntimeError('injected ' + stage)
        with self.assertRaisesRegex(RuntimeError, 'injected'):
            self.apply(failpoint=fail, run_name=name)
        self.assertEqual([p.parent.name for p in d.pending(self.home)], [name])
        d.recover(self.home, self.home / '.ctxhop-desktop-recovery' / name, guard=self.guard)
        with self.assertRaises(FileExistsError):
            self.apply(run_name=name)
        self.assertIsNone(d.selected(self.home, self.thread_id))
        result = self.apply(run_name='cd' * 16)
        self.assertEqual(Path(result['recovery']).name, 'cd' * 16)
        self.assertEqual(json.loads((Path(result['recovery']) / 'journal.json').read_text(encoding='utf-8'))['status'], 'complete')

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
        Path(journal['members'][0]['path']).write_bytes(b'new user changes\n')
        with self.assertRaisesRegex(ValueError, '파일이 변경'):
            d.recover(self.home, run, guard=self.guard)

    def test_13_page_search_all_projects(self):
        self.apply()
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            row = d.selected(self.home, self.thread_id)['members'][0]['data']['thread']
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
        bad['members'][0]['data']['thread']['title'] = None
        with self.assertRaisesRegex(ValueError, '필수'):
            d.validate_family(bad)
        bad = copy.deepcopy(self.original)
        bad['manifest']['engineVersion'] = 'unknown'
        with self.assertRaisesRegex(ValueError, '버전'):
            d.validate_family(bad)

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
        full, original = self.full['members'][0], self.original['members'][0]
        if d.canonical(full['rollout'], self.thread_id) == d.canonical(original['rollout'], self.thread_id):
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
        with mock.patch.object(d, 'engine_version', return_value='0.158.0-alpha.2.1'):
            code, result = self.run_cli('export', '--home', str(FIXTURE), '--id', self.thread_id, '--output', str(output))
        self.assertEqual(code, 0)
        self.assertEqual(set(result['metadata']), {'sessionId', 'title', 'sourceCwd', 'updatedAt', 'historyMode', 'cliVersion', 'recordCount'})
        self.assertEqual(result['metadata']['cliVersion'], '0.158.0-alpha.2.1')
        self.assertRegex(result['metadata']['updatedAt'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertRegex(result['metadata']['historyMode'], r'^paginated;family=0$')
        self.assertEqual(d.read_archive(output)['manifest']['engineVersion'], '0.158.0-alpha.2.1')
        code, page = self.run_cli('list', '--home', str(FIXTURE), '--search', self.thread_id[:8])
        self.assertEqual((code, page['total']), (0, 1))
        self.assertEqual(set(page['sessions'][0]), {'id', 'title', 'cwd', 'historyMode', 'archived', 'children', 'updatedAt'})
        self.assertIs(type(page['sessions'][0]['archived']), bool)
        self.assertEqual(page['sessions'][0]['children'], 0)
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
        with mock.patch.object(d, 'engine_version', return_value=d.VERSIONS[-1]):
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

    def test_22_preview_blocks_engine_mismatch_and_hides_subagents(self):
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
        # 부모 없는 내부 도우미 대화(예: guardian)도 하위 에이전트 source라 목록과 백업 대상에서 빠진다.
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('UPDATE threads SET source=? WHERE id=?', ('{"subagent":{"other":"guardian"}}', self.thread_id))
        self.assertEqual(d.list_sessions(self.home)['total'], 0)
        with self.assertRaisesRegex(ValueError, '부모 대화'):
            d.selected(self.home, self.thread_id)
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
            family = d.read_archive(self.append(label))
            family['manifest']['engineVersion'] = old
            archive = self.root / (label + '-old.zip')
            d.write_archive(family, archive)
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

    # 하위 에이전트 대화 묶음

    def test_27_family_round_trip_and_list(self):
        family = self.family([0, 0, 1])  # 최상위 아래 둘, 첫 하위 아래 하나(중첩)
        archive = self.save(family, 'family')
        preview = self.preview(archive)
        self.assertEqual(preview['status'], 'new')
        self.assertIn('하위 대화 3개', preview['reason'])
        self.assertEqual((preview['source']['children'], preview['source']['historyMode']), (3, 'paginated;family=3'))
        result = self.apply(archive)
        self.assertEqual((result['status'], result['members']), ('imported', 4))
        restored = d.selected(self.home, self.thread_id)
        self.assertEqual(sorted(self.ids(restored)), sorted(self.ids(family)))
        self.assertEqual(self.edges(), sorted(tuple(edge.values()) for edge in family['edges']))
        sources = {item['data']['thread']['id']: item for item in family['members']}
        for item in restored['members']:
            thread_id = item['data']['thread']['id']
            header = d.records(item['rollout'], thread_id, [self.thread_id])[0]['payload']
            self.assertEqual((item['data']['thread']['cwd'], header['cwd']), (str(self.cwd), str(self.cwd)))
            source = d.records(sources[thread_id]['rollout'], thread_id, [self.thread_id])[0]['payload']
            self.assertEqual(header.get('parent_thread_id'), source.get('parent_thread_id'))
        page = d.list_sessions(self.home)
        self.assertEqual((page['total'], page['sessions'][0]['id'], page['sessions'][0]['children']), (1, self.thread_id, 3))
        with self.assertRaisesRegex(ValueError, '부모 대화'):
            d.selected(self.home, self.ids(family)[3])
        self.assertEqual(self.preview(archive)['status'], 'equal')
        # 내보내기: 부모를 고르면 묶음 전체, 하위 대화 ID는 차단
        output = self.root / 'family-export.zip'
        with mock.patch.object(d, 'engine_version', return_value=d.VERSIONS[-1]):
            code, exported = self.run_cli('export', '--home', str(self.home), '--id', self.thread_id, '--output', str(output))
            self.assertEqual((code, exported['metadata']['historyMode']), (0, 'paginated;family=3'))
            # 프로젝트 폴더 백업이 쓸 작업 폴더: 가져온 묶음은 모두 가져올 때 고른 폴더를 쓴다.
            self.assertEqual(exported['folders'], {'cwds': [str(self.cwd)], 'edits': []})
            code, blocked = self.run_cli('export', '--home', str(self.home), '--id', self.ids(family)[1],
                '--output', str(self.root / 'child-export.zip'))
        self.assertEqual(code, 1)
        self.assertIn('부모 대화', blocked['reason'])
        self.assertEqual(sorted(self.ids(d.read_archive(output))), sorted(self.ids(family)))

    def test_28_family_merge_keeps_local_newer_children(self):
        base = self.family([0, 0])
        a, b = self.ids(base)[1:]
        self.apply(self.save(self.grown(base, 2, 'b-local'), 'local'))
        incoming = self.family([1], base=self.grown(base, 1, 'a-newer'))  # a 이어짐, b 이 PC가 더 최신, c 새로(a 아래)
        incoming['edges'][0]['status'] = 'closed'
        archive = self.save(incoming, 'incoming')
        preview = self.preview(archive)
        self.assertEqual(preview['status'], 'incoming_newer')
        for part in ('새로 1', '이어짐 1', '이 PC가 더 최신 1'):
            self.assertIn(part, preview['reason'])
        result = self.apply(archive)
        self.assertEqual(result['members'], 2)
        after = {item['data']['thread']['id']: item for item in d.selected(self.home, self.thread_id)['members']}
        self.assertEqual(len(after), 4)
        chain = [self.thread_id]
        self.assertEqual(d.canonical(after[a]['rollout'], a, chain), d.canonical(incoming['members'][1]['rollout'], a, chain))
        local_b = self.grown(base, 2, 'b-local')['members'][2]['rollout']
        self.assertEqual(d.canonical(after[b]['rollout'], b, chain), d.canonical(local_b, b, chain))
        self.assertIn((self.thread_id, a, 'closed'), self.edges())
        self.assertEqual(self.preview(archive)['status'], 'local_newer')

    def test_29_family_conflict_is_one_choice(self):
        base = self.family([0])
        local, shared = self.grown(base, 1, 'child-local'), self.grown(base, 1, 'child-shared')
        self.apply(self.save(local, 'local'))
        local_state = d.selected(self.home, self.thread_id)
        archive = self.save(shared, 'shared')
        self.assertEqual(self.preview(archive)['status'], 'conflict')
        self.assertEqual(self.apply(archive, choice='skip')['status'], 'skipped')
        result = self.apply(archive)
        self.assertEqual(result['members'], 1)
        self.assertEqual(self.preview(archive)['status'], 'equal')
        # before.zip은 이 PC 묶음 전체라 그대로 되살릴 수 있다.
        before = d.read_archive(Path(result['recovery']) / 'before.zip')
        self.assertEqual(d.snapshot_hash(before), d.snapshot_hash(local_state))

    def test_30_family_recovery_removes_new_children_and_edges(self):
        family = self.family([0, 1])
        archive = self.save(family, 'family')
        def fail(stage):
            raise RuntimeError('injected ' + stage)
        with self.assertRaises(RuntimeError):
            self.apply(archive, failpoint=fail)
        run = d.pending(self.home)[0].parent
        self.assertEqual(len(json.loads((run / 'journal.json').read_text(encoding='utf-8'))['edges']), 2)
        d.recover(self.home, run, guard=self.guard)
        self.assertIsNone(d.selected(self.home, self.thread_id))
        self.assertEqual(self.edges(), [])
        self.assertEqual(list((self.home / 'sessions').rglob('*.jsonl')), [])
        # 기존 묶음을 갱신하다 커밋 뒤 중단: 이어진 하위 대화·새 하위 대화·연결 상태가 모두 이전으로 돌아간다.
        base = self.family([0])
        self.apply(self.save(base, 'base'))
        before, before_edges = d.selected(self.home, self.thread_id), self.edges()
        incoming = self.family([1], base=self.grown(base, 1, 'more'))
        incoming['edges'][0]['status'] = 'closed'
        def after_commit(stage):
            if stage == 'commit':
                raise RuntimeError('injected commit')
        with self.assertRaises(RuntimeError):
            self.apply(self.save(incoming, 'incoming'), failpoint=after_commit)
        run = d.pending(self.home)[0].parent
        self.assertEqual(d.recover(self.home, run, guard=self.guard)['members'], 2)
        self.assertEqual(d.snapshot_hash(d.selected(self.home, self.thread_id)), d.snapshot_hash(before))
        self.assertEqual(self.edges(), before_edges)
        self.assertFalse(any(self.ids(incoming)[2] in p.name for p in (self.home / 'sessions').rglob('*.jsonl')))

    def test_31_recovery_refuses_links_added_after_failure(self):
        archive = self.save(self.family([0]), 'family')
        def fail(stage):
            raise RuntimeError('injected ' + stage)
        with self.assertRaises(RuntimeError):
            self.apply(archive, failpoint=fail)
        run = d.pending(self.home)[0].parent
        child = json.loads((run / 'journal.json').read_text(encoding='utf-8'))['members'][1]['id']
        with sqlite3.connect(self.home / d.FILES[0]) as db:
            db.execute('INSERT INTO thread_spawn_edges VALUES (?,?,?)', (child, str(uuid.uuid4()), 'open'))
        with self.assertRaisesRegex(ValueError, '다른 작업'):
            d.recover(self.home, run, guard=self.guard)

    def legacy_archive(self, item, path):
        """이전 판 형식 1 보관 파일(대화 하나, manifest에 sessions 없음)."""
        d.seal(path, {'format': 1, 'schema': d.trusted_schema(), 'engineVersion': d.VERSIONS[-1]},
            {'data.json': d.encoded(item['data']), 'rollout.jsonl': item['rollout']})
        return path

    def test_32_format1_archive_and_legacy_journal(self):
        old = self.legacy_archive(self.original['members'][0], self.root / 'format1.zip')
        family = d.read_archive(old)
        self.assertEqual((len(family['members']), family['edges']), (1, []))
        self.assertEqual(d.summary(family)['historyMode'], 'paginated')
        self.assertEqual(self.preview(old)['status'], 'new')
        self.apply(old)
        self.assertEqual(self.preview(old)['status'], 'equal')
        before = d.selected(self.home, self.thread_id)
        # 이전 판이 커밋 뒤 중단하며 남긴 복구 기록(journal에 version 없음, before.zip·incoming.zip·undo)도 되돌린다.
        def after_commit(stage):
            if stage == 'commit':
                raise RuntimeError('injected commit')
        with self.assertRaises(RuntimeError):
            self.apply(self.append('newer'), failpoint=after_commit)
        run = d.pending(self.home)[0].parent
        journal = json.loads((run / 'journal.json').read_text(encoding='utf-8'))
        entry = journal['members'][0]
        (run / 'before.zip').unlink()
        self.legacy_archive(before['members'][0], run / 'before.zip')
        self.legacy_archive(d.read_member_archive(run / 'incoming-0000.zip'), run / 'incoming.zip')
        (run / 'incoming-0000.zip').unlink()
        legacy = {'status': 'pending', 'home': journal['home'], 'createdDb': [], 'beforeData': None, 'afterData': None,
            **{key: entry[key] for key in ('id', 'path', 'before', 'after', 'beforeFile', 'afterFile')}}
        (run / 'journal.json').write_bytes(d.encoded(legacy))
        self.assertEqual(d.recover(self.home, run, guard=self.guard)['status'], 'rolled_back')
        self.assertEqual(d.snapshot_hash(d.selected(self.home, self.thread_id)), d.snapshot_hash(before))

    def test_33_family_validation_and_foreign_child(self):
        family = self.family([0])
        bad = copy.deepcopy(family)
        bad['members'][1]['data']['thread']['source'] = 'vscode'
        with self.assertRaisesRegex(ValueError, '하위 대화가 아닌'):
            d.validate_family(bad)
        bad = copy.deepcopy(family)
        bad['edges'][0]['parent_thread_id'] = bad['edges'][0]['child_thread_id']
        with self.assertRaisesRegex(ValueError, '연결'):
            d.validate_family(bad)
        bad = copy.deepcopy(family)
        bad['edges'] = []
        with self.assertRaisesRegex(ValueError, '연결'):
            d.validate_family(bad)
        bad = copy.deepcopy(family)
        bad['members'].reverse()
        with self.assertRaisesRegex(ValueError, '부모 대화'):
            d.validate_family(bad)
        # 같은 하위 대화 ID가 이 PC에서 다른 최상위 대화에 붙어 있으면 가져오지 않는다.
        self.apply(self.save(family, 'family'))
        root, child = self.original['members'][0], family['members'][1]
        other_id, child_id = str(uuid.uuid4()), child['data']['thread']['id']
        other = copy.deepcopy(self.original)
        other['members'] = [self.rekeyed(root, other_id, root['data']['thread']['source'], session_id=other_id),
            self.rekeyed(child, child_id, child['data']['thread']['source'], parent_thread_id=other_id, session_id=other_id)]
        other['edges'] = [{'parent_thread_id': other_id, 'child_thread_id': child_id, 'status': 'open'}]
        d.validate_family(other)
        with self.assertRaisesRegex(ValueError, '다른 대화에 연결'):
            self.preview(self.save(other, 'other'))

    def test_34_native_reads_imported_children(self):
        family = self.family([0, 1])
        self.apply(self.save(family, 'family'))
        rpc = Rpc(EXE, self.home)
        try:
            for child_id in self.ids(family)[1:]:
                read = rpc.call('thread/read', {'threadId': child_id, 'includeTurns': False})
                self.assertEqual(read['thread']['id'], child_id)
                items = rpc.call('thread/items/list', {'threadId': child_id, 'limit': 20})
                self.assertIn('CTXHOP_NATIVE_FIXTURE_USER', json.dumps(items, ensure_ascii=False))
            (self.root / 'native-children.json').write_text(json.dumps(read, ensure_ascii=False, indent=2), encoding='utf-8')
        finally:
            rpc.close()

    def test_35_export_with_app_running_skips_active_turns(self):
        # 백업은 앱 종료를 보지 않는다. 묶음의 대화가 턴을 진행 중이면(최근 15분 안에 기록) busy로 멈추고 파일을 만들지 않는다.
        self.apply(self.save(self.family([0]), 'family'))
        child = d.selected(self.home, self.thread_id)['members'][1]
        path = d.rollout_path(self.home, child['data']['thread']['rollout_path'])
        output = self.root / 'export.zip'

        def export():
            output.unlink(missing_ok=True)
            with mock.patch.object(d, 'assert_no_writers', side_effect=ValueError('Codex 앱이 실행 중')), \
                    mock.patch.object(d, 'engine_version', return_value=d.VERSIONS[-1]):
                return self.run_cli('export', '--home', str(self.home), '--id', self.thread_id, '--output', str(output))

        def event(kind):
            with open(path, 'ab') as f:
                f.write(d.encoded({'timestamp': '2026-09-27T05:00:00Z', 'type': 'event_msg',
                    'payload': {'type': kind, 'turn_id': 'turn-open'}}) + b'\n')

        def db_time(t):
            with sqlite3.connect(self.home / d.FILES[0]) as db:
                db.execute('UPDATE threads SET updated_at=?, updated_at_ms=? WHERE id=?', (int(t), int(t * 1000), child['data']['thread']['id']))

        self.assertEqual(export()[0], 0)
        event('task_started')
        code, busy = export()
        self.assertEqual((code, busy['status']), (1, 'busy'))
        self.assertIn('진행 중', busy['reason'])
        self.assertFalse(output.exists())
        old = time.time() - d.ACTIVE_SECONDS - 60
        os.utime(path, (old, old))  # 앱이 연 채로 이어 쓰는 파일은 수정 시각이 늦게 바뀐다. DB 수정 시각이 최근이면 진행 중이다.
        db_time(time.time())
        self.assertEqual(export()[1]['status'], 'busy')
        db_time(old)  # 앱 강제 종료 등으로 끊긴 채 오래된 턴은 끝난 것으로 본다
        self.assertEqual(export()[0], 0)
        event('task_complete')
        self.assertEqual(export()[0], 0)
        self.assertEqual(sorted(self.ids(d.read_archive(output))), sorted(self.ids(d.selected(self.home, self.thread_id))))
        # 내보내는 동안 묶음이 바뀌면 busy로 멈춘다.
        write = d.write_archive

        def write_then_change(family, target):
            write(family, target)
            event('user_message')
        with mock.patch.object(d, 'write_archive', side_effect=write_then_change):
            code, changed = export()
        self.assertEqual((code, changed['status']), (1, 'busy'))
        self.assertIn('변경', changed['reason'])
        # 처음 읽을 때 앱과 겹쳐 한 번 실패하면 다시 읽어 백업한다.
        real, calls = d.selected, []

        def flaky(home, thread_id):
            calls.append(thread_id)
            if len(calls) == 1:
                raise ValueError('이력 파일 위치가 범위를 벗어났습니다.')
            return real(home, thread_id)
        with mock.patch.object(d, 'selected', side_effect=flaky), mock.patch.object(d.time, 'sleep'):
            self.assertEqual(export()[0], 0)
        self.assertEqual(len(calls), 3)
        # 내보낸 뒤 세션 파일이 옮겨져(보관 등) 다시 읽지 못해도 바뀐 것이므로 busy다.
        moved = path.with_name(path.name + '.moved')

        def write_then_move(family, target):
            write(family, target)
            path.rename(moved)
        with mock.patch.object(d, 'write_archive', side_effect=write_then_move):
            code, gone = export()
        moved.rename(path)
        self.assertEqual((code, gone['status']), (1, 'busy'))
        # 앱이 한 줄을 쓰는 도중이라 다시 읽지 못해도 바뀐 것이므로 실패가 아니라 busy다.

        def write_then_partial(family, target):
            write(family, target)
            with open(path, 'ab') as f:
                f.write(b'{"timestamp":"2026-09-27T05:00:01Z","type":"event_')
        with mock.patch.object(d, 'write_archive', side_effect=write_then_partial):
            code, partial = export()
        self.assertEqual((code, partial['status']), (1, 'busy'))
        # 다시 읽어도 못 읽는 세션 파일은 진행 중으로 숨기지 않고 실패로 보고한다.
        with mock.patch.object(d.time, 'sleep'):
            code, broken = export()
        self.assertEqual((code, broken['status']), (1, 'blocked'))
        self.assertFalse(output.exists())

    def test_36_writer_check_runs_system_powershell(self):
        # 이름만 주면 python.exe 폴더와 현재 폴더의 같은 이름 파일이 먼저 실행되므로 System32의 전체 경로여야 한다.
        with mock.patch.dict(os.environ, {'SystemRoot': r'C:\Windows'}), \
                mock.patch.object(d.subprocess, 'run', return_value=mock.Mock(returncode=0)) as run:
            d.assert_no_writers()
        self.assertEqual(run.call_args[0][0][0], r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')

    def test_37_work_folders_lists_every_cwd_and_absolute_patch_paths(self):
        # 패치는 function_call arguments처럼 JSON 문자열 안에 JSON으로 한 번 더 들어 있을 수 있다. 상대 경로는 작업 폴더 안이라 빼고,
        # 같은 경로는 한 번만, 대화 cwd → 턴마다 바뀐 cwd → 하위 대화 cwd 순으로 처음 본 순서를 지킨다.
        def line(kind, payload):
            return (json.dumps({'type': kind, 'payload': payload}, ensure_ascii=False) + '\n').encode('utf-8')
        patch = '*** Begin Patch\n*** Update File: D:\\codex\\보고서\\a.py\n*** Add File: notes/b.md\n*** End Patch'
        parent = (line('session_meta', {'id': 'p'}) + line('turn_context', {'cwd': 'D:\\codex\\보고서'})
            + line('turn_context', {'cwd': 'D:\\other'})
            + line('response_item', {'type': 'function_call', 'name': 'shell',
                'arguments': json.dumps({'command': ['apply_patch', patch]}, ensure_ascii=False)})
            + line('response_item', {'type': 'custom_tool_call', 'name': 'apply_patch',
                'input': '*** Begin Patch\n*** Delete File: C:\\Users\\me\\Desktop\\x.txt\n*** End Patch'})
            + line('response_item', {'type': 'custom_tool_call', 'name': 'apply_patch', 'input': patch}))
        child = line('session_meta', {'id': 'c'}) + line('turn_context', {'cwd': 'E:\\sub'})
        family = {'members': [{'data': {'thread': {'cwd': 'D:\\codex\\보고서'}}, 'rollout': parent},
            {'data': {'thread': {'cwd': 'E:\\sub'}}, 'rollout': child}]}
        self.assertEqual(d.work_folders(family), {'cwds': ['D:\\codex\\보고서', 'D:\\other', 'E:\\sub'],
            'edits': ['D:\\codex\\보고서\\a.py', 'C:\\Users\\me\\Desktop\\x.txt']})

    def with_settings(self, item, **values):
        """세션 파일의 모든 설정 기록(turn_context, thread_settings_applied)에 values를 넣은(None이면 뺀) 사본. 이력 행은 비운다(위치가 바뀌므로)."""
        item = copy.deepcopy(item)
        lines = []
        for obj in d.records(item['rollout'], item['data']['thread']['id']):
            settings = d.settings_record(obj)
            for key, value in values.items() if settings is not None else ():
                if value is None:
                    settings.pop(key, None)
                else:
                    settings[key] = value
            lines.append(d.encoded(obj) + b'\n')
        item['rollout'] = b''.join(lines)
        item['data']['history'] = {table: [] for table in d.TABLES}
        return item

    def test_38_restore_replaces_every_resume_setting(self):
        # 엔진은 이어 쓸 때 마지막 설정 기록의 승인·권한과 소유 thread_settings_applied의 작업 폴더를 쓴다.
        # 원래 PC의 never·전체 권한·작업 루트가 어느 기록에 있든 복원 후에는 이 PC 값만 남아야 한다.
        unsafe = {'approval_policy': 'never', 'active_permission_profile': {'id': ':danger-full-access'}}
        source = self.with_settings(self.original['members'][0], **unsafe)
        path = self.home / 'sessions' / 'x.jsonl'
        restored = d.mapped(source, self.cwd, path, None)
        parsed = d.records(restored['rollout'], self.thread_id)
        self.assertEqual(d.resume_settings(parsed), d.SAFE_SETTINGS)
        owned = [d.settings_record(o) for o in parsed if o['type'] == 'event_msg'
            and o['payload'].get('type') == 'thread_settings_applied' and o['payload'].get('thread_id') == self.thread_id]
        self.assertTrue(owned, 'fixture에 소유 thread_settings_applied가 있어야 한다')
        self.assertEqual(owned[-1]['cwd'], str(self.cwd))
        self.assertEqual(owned[-1].get('runtime_workspace_roots', [str(self.cwd)]), [str(self.cwd)])
        self.assertEqual(d.canonical(restored['rollout'], self.thread_id), d.canonical(source['rollout'], self.thread_id))
        # 이 PC에 같은 대화가 있으면 그 대화의 현재 승인·권한을 그대로 둔다.
        local = self.with_settings(self.original['members'][0], approval_policy='on-request',
            active_permission_profile={'id': ':workspace'})
        kept = d.mapped(source, self.cwd, path, local)
        self.assertEqual(d.resume_settings(d.records(kept['rollout'], self.thread_id)),
            d.resume_settings(d.records(local['rollout'], self.thread_id)))

    def reviewer_shape(self, item, order, last):
        """앞 기록에 승인자 auto_review가 있고 마지막 turn_context의 승인자가 없거나(last='missing') null인 사본.
        order='tsa'는 끝의 thread_settings_applied를 헤더 뒤로 옮기고, 'tc'는 앞 turn_context를 하나 더 두고 끝의 설정 기록을 뺀다."""
        item = self.with_settings(item)
        objs = d.records(item['rollout'], self.thread_id)
        at = max(i for i, o in enumerate(objs) if o['type'] == 'turn_context')
        tail = [o for o in objs[at + 1:] if d.settings_record(o) is None]
        if order == 'tsa':
            early = [o for o in objs[at + 1:] if d.settings_record(o) is not None]
            self.assertTrue(early, 'fixture 끝에 thread_settings_applied가 있어야 한다')
        else:
            early = [copy.deepcopy(objs[at])]
        for o in early:
            d.settings_record(o)['approvals_reviewer'] = 'auto_review'
        objs = objs[:1] + early + objs[1:at + 1] + tail if order == 'tsa' else objs[:at] + early + objs[at:at + 1] + tail
        context = [o for o in objs if o['type'] == 'turn_context'][-1]['payload']
        if last == 'missing':
            context.pop('approvals_reviewer', None)
        else:
            context['approvals_reviewer'] = None
        item['rollout'] = b''.join(d.encoded(o) + b'\n' for o in objs)
        return item

    def engine_resume(self, item, label):
        """세션 파일 하나만 둔 새 격리 홈에서 실제 엔진이 요청 값 없이 이어 쓸 때 고르는 (승인 정책, 승인자, 권한 프로필 ID)."""
        day = self.root / label / 'sessions' / '2026' / '09' / '27'  # 긴 시험 폴더에서도 260자를 넘지 않게 짧은 이름
        day.mkdir(parents=True)
        (day / f'rollout-2026-09-27T00-00-00-{self.thread_id}.jsonl').write_bytes(item['rollout'])
        rpc = Rpc(EXE, day.parents[3])
        try:
            r = rpc.call('thread/resume', {'threadId': self.thread_id, 'excludeTurns': True, 'modelProvider': 'openai'})
        finally:
            rpc.close()
        return r['approvalPolicy'], r['approvalsReviewer'], (r.get('activePermissionProfile') or {}).get('id')

    def test_41_resume_settings_follow_engine_and_keep_local_reviewer(self):
        # 마지막 turn_context에 승인자가 없거나 null이면 엔진은 앞 기록의 승인자를 쓴다(persisted_resume_settings.rs).
        # 덮어쓰기 전후 엔진이 고르는 값이 같아야 하고, 처음 가져오는 대화는 원래 PC의 앞 기록으로 돌아가지 않아야 한다.
        path = self.home / 'sessions' / 'x.jsonl'
        item = self.original['members'][0]
        # 원래 PC: 승인자 user, never·전체 권한, turn_context 두 개.
        source = self.with_settings(item, approval_policy='never', approvals_reviewer='user',
            active_permission_profile={'id': ':danger-full-access'})
        objs = d.records(source['rollout'], self.thread_id)
        at = max(i for i, o in enumerate(objs) if o['type'] == 'turn_context')
        source['rollout'] = b''.join(d.encoded(o) + b'\n' for o in objs[:at] + [copy.deepcopy(objs[at])] + objs[at:])
        for order in ('tsa', 'tc'):
            for last in ('missing', 'null'):
                label = order + last[0]
                local = self.reviewer_shape(item, order, last)
                before = self.engine_resume(local, label + 'l')
                self.assertEqual(before[1], 'auto_review', label)
                settings = d.resume_settings(d.records(local['rollout'], self.thread_id))
                self.assertEqual((settings['approval_policy'], settings['approvals_reviewer']), before[:2], label)
                self.assertEqual(self.engine_resume(d.mapped(source, self.cwd, path, local), label + 'k'), before, label)
                restored = d.mapped(self.reviewer_shape(item, order, last), self.cwd, path, None)
                self.assertEqual(self.engine_resume(restored, label + 'n'), ('untrusted', 'user', ':read-only'), label)
        # 이 PC 대화 어디에도 승인자가 없으면(엔진은 설정 기본값을 씀) 원래 PC 앞 기록의 승인자가 끼어들지 않아야 한다.
        bare = self.with_settings(item, approvals_reviewer=None)
        bare['rollout'] = b''.join(d.encoded(o) + b'\n' for o in d.records(bare['rollout'], self.thread_id)
            if o['type'] != 'event_msg' or d.settings_record(o) is None)
        expected = self.engine_resume(bare, 'bare')
        for last in ('missing', 'null'):
            kept = d.mapped(self.reviewer_shape(item, 'tc', last), self.cwd, path, bare)
            self.assertEqual(self.engine_resume(kept, 'bare' + last[0]), expected, last)

    def test_39_old_app_tools_are_backed_up_and_restored(self):
        # 옛 Codex 앱이 헤더에 남긴 동적 도구가 있어도 백업·복원하고, 미리보기에서 알린다.
        item = self.original['members'][0]
        tools = [{'namespace': 'codex_app', 'name': 'create_thread', 'description': 'old app tool', 'inputSchema': {}}]
        family = copy.deepcopy(self.original)
        family['members'][0] = self.rekeyed(item, self.thread_id, item['data']['thread']['source'], dynamic_tools=tools)
        archive = self.save(family, 'old-tools')
        preview = self.preview(archive)
        self.assertEqual(preview['status'], 'new')
        self.assertIn('옛 Codex 앱 도구', preview['reason'])
        self.assertNotIn('옛 Codex 앱 도구', self.preview()['reason'])
        self.assertEqual(self.apply(archive)['status'], 'imported')
        output = self.root / 'old-tools-export.zip'
        with mock.patch.object(d, 'engine_version', return_value=d.VERSIONS[-1]):
            code, result = self.run_cli('export', '--home', str(self.home), '--id', self.thread_id, '--output', str(output))
        self.assertEqual(code, 0, result)
        header = json.loads(d.read_archive(output)['members'][0]['rollout'].split(b'\n', 1)[0])['payload']
        self.assertEqual(header['dynamic_tools'], tools)

    def test_40_pending_restore_blocks_only_its_conversations(self):
        item = self.original['members'][0]
        other_id = str(uuid.uuid4())
        other = copy.deepcopy(self.original)
        other['members'][0] = self.rekeyed(item, other_id, item['data']['thread']['source'], session_id=other_id)
        self.apply(self.save(other, 'other'))
        self.apply()
        def fail(stage):
            if stage == 'commit':
                raise RuntimeError('injected commit')
        with self.assertRaisesRegex(RuntimeError, 'commit'):
            self.apply(self.append('after'), failpoint=fail)
        self.assertEqual(d.pending_ids(self.home), {self.thread_id})
        with mock.patch.object(d, 'engine_version', return_value=d.VERSIONS[-1]):
            code, blocked = self.run_cli('export', '--home', str(self.home), '--id', self.thread_id,
                '--output', str(self.root / 'blocked.zip'))
            self.assertEqual((code, blocked['status']), (1, 'blocked'))
            self.assertIn('먼저 복구', blocked['reason'])
            code, result = self.run_cli('export', '--home', str(self.home), '--id', other_id,
                '--output', str(self.root / 'other-export.zip'))
        self.assertEqual((code, result['status']), (0, 'exported'))
        # 정상 기록(형식 1, 하위 대화만 쓴 형식 2)은 다른 대화의 백업을 막지 않고,
        # 대상을 확정할 수 없는 기록은 모든 백업을 막는다.
        def record(text):
            run = self.home / '.ctxhop-desktop-recovery' / uuid.uuid4().hex
            run.mkdir()
            (run / 'journal.json').write_text(text, encoding='utf-8')
            return run
        def export_other():
            with mock.patch.object(d, 'engine_version', return_value=d.VERSIONS[-1]):
                return self.run_cli('export', '--home', str(self.home), '--id', other_id,
                    '--output', str(self.root / (uuid.uuid4().hex + '.zip')))
        record(json.dumps({'status': 'pending', 'id': str(uuid.uuid4())}))
        record(json.dumps({'status': 'pending', 'version': 2, 'id': self.thread_id, 'members': [{'id': str(uuid.uuid4())}]}))
        self.assertEqual(export_other()[1]['status'], 'exported')
        for label, text in [('bad json', '{'), ('unknown version', {'version': 3, 'members': [{'id': other_id}]}),
                ('no members', {'version': 2, 'id': other_id}), ('empty members', {'version': 2, 'members': []}),
                ('null id', {'version': 2, 'members': [{'id': None}]}), ('bad id', {'version': 2, 'members': [{'id': 'x'}]}),
                ('format 1 without id', {})]:
            run = record(text if isinstance(text, str) else json.dumps({'status': 'pending', **text}))
            code, result = export_other()
            self.assertEqual((code, result['status']), (1, 'blocked'), label)
            if label != 'bad json':
                self.assertIn('손상', result['reason'], label)
            shutil.rmtree(run)
        self.assertEqual(export_other()[1]['status'], 'exported')


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
