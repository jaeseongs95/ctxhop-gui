"""Codex Desktop 선택 세션 이식. 표준 라이브러리만 사용한다."""
import argparse
import base64
import copy
import contextlib
import datetime
import functools
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import uuid
import zipfile
from pathlib import Path

# 아래 DB 구조(schema.json)와 격리 native 시험을 통과한 Desktop 엔진 빌드만 허용한다.
VERSIONS = ('0.158.0-alpha.2', '0.158.0-alpha.2.1')
SCHEMA_HASH = 'd24acac2105569b5b9cfdabc5259db8217b9a9f175d7d2b57a09a2d4f76fa0a2'
FILES = ('state_5.sqlite', 'thread_history_1.sqlite')
TABLES = ('thread_turns', 'thread_items', 'thread_history_projection_state', 'thread_realtime_items')
LIMIT = 1024 * 1024 * 1024
LOCAL_FIELDS = ('project_id', 'thread_section_id', 'is_pinned', 'section_position',
    'section_entered_at_ms', 'creator_user_id', 'creator_account_id', 'sandbox_policy',
    'approval_mode', 'memory_mode', 'daybreak_enabled')


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def native_id(value):
    if str(uuid.UUID(value)) != value.lower() or not re.fullmatch(r'[0-9a-fA-F-]{36}', value):
        raise ValueError('세션 UUID가 올바르지 않습니다.')
    return value.lower()


def trusted_schema():
    data = Path(__file__).with_name('schema.json').read_bytes()
    if digest(data) != SCHEMA_HASH:
        raise ValueError('배포 DB 구조 파일 검증 실패')
    return json.loads(data)


@contextlib.contextmanager
def ro(path):
    db = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA query_only=ON')
    try:
        yield db
    finally:
        db.close()


def schema_of(db):
    objects = [list(row) for row in db.execute("SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL "
        "AND name NOT LIKE 'sqlite_%' ORDER BY type,name")]
    migrations = [[v,d,s,base64.b64encode(c).decode()] for v,d,s,c in db.execute(
        'SELECT version,description,success,checksum FROM _sqlx_migrations ORDER BY version')]
    return {'objects': objects, 'migrations': migrations}


def absolute(path):
    value = str(path)
    if value.startswith('\\\\?\\UNC\\'):
        value = '\\\\' + value[8:]
    elif value.startswith('\\\\?\\'):
        value = value[4:]
    return Path(os.path.abspath(value))


def check_home(home):
    home = absolute(home)
    no_reparse(home)
    if not home.is_dir():
        raise ValueError('Codex 저장소 폴더가 없습니다.')
    return home


def no_reparse(path):
    path = absolute(path)
    for node in (path, *path.parents):
        if node.exists() or node.is_symlink():
            attrs = getattr(node.lstat(), 'st_file_attributes', 0)
            if node.is_symlink() or attrs & 0x400:
                raise ValueError('링크/연결 폴더는 변경 대상으로 사용할 수 없습니다.')


def rollout_path(home, path):
    path = absolute(path)
    no_reparse(path)
    if not any(path.is_relative_to(home / name) for name in ('sessions', 'archived_sessions')):
        raise ValueError('세션 파일이 Codex 세션 폴더 밖에 있습니다.')
    if path.suffix != '.jsonl':
        raise ValueError('세션 파일 확장자가 다릅니다.')
    return path


def check_schema(home, allow_missing=False):
    expected = trusted_schema()
    for name in FILES:
        path = home / name
        no_reparse(path)
        if not path.exists() and allow_missing:
            continue
        with ro(path) as db:
            if schema_of(db) != expected[name]:
                raise ValueError(f'{name}: 지원하는 Desktop DB 구조와 다릅니다.')


def create_database(path, name):
    # archive의 SQL은 실행하지 않는다. 배포본에 고정된 native 구조만 사용한다.
    schema = trusted_schema()[name]
    with sqlite3.connect(path) as db:
        for kind in ('table', 'index', 'trigger', 'view'):
            for obj_type, obj_name, sql in schema['objects']:
                if obj_type == kind:
                    db.execute(sql)
        for version, description, success, checksum in schema['migrations']:
            db.execute('INSERT INTO _sqlx_migrations VALUES (?,?,CURRENT_TIMESTAMP,?,?,0)',
                (version, description, success, base64.b64decode(checksum)))


def records(raw, thread_id):
    if not raw or len(raw) > LIMIT or not raw.endswith(b'\n'):
        raise ValueError('세션 파일이 비었거나 불완전합니다.')
    result = []
    for line in raw.splitlines():
        if not line or len(line) > 16 * 1024 * 1024:
            raise ValueError('세션 레코드 크기가 올바르지 않습니다.')
        obj = json.loads(line)
        if not isinstance(obj, dict) or not isinstance(obj.get('payload'), dict):
            raise ValueError('세션 레코드 구조가 올바르지 않습니다.')
        result.append(obj)
    header = result[0]
    if header.get('type') != 'session_meta' or header['payload'].get('id') != thread_id:
        raise ValueError('세션 헤더 ID가 다릅니다.')
    if header['payload'].get('session_id', thread_id) != thread_id:
        raise ValueError('세션 헤더 session_id가 다릅니다.')
    return result


@functools.lru_cache(maxsize=1)
def expected_columns():
    result = {}
    for name, schema in trusted_schema().items():
        with sqlite3.connect(':memory:') as db:
            for kind, table, sql in schema['objects']:
                if kind == 'table':
                    db.execute(sql)
            for table in (('threads',) if name == FILES[0] else TABLES):
                result[table] = {row[1]: (row[2], row[3]) for row in db.execute(f'PRAGMA table_info({table})')}
    return result


def validate_row(row, table):
    columns = expected_columns()[table]
    if not isinstance(row, dict) or set(row) != set(columns):
        raise ValueError(f'{table}: DB 열 목록이 다릅니다.')
    for key, value in row.items():
        if value is None:
            if columns[key][1]:
                raise ValueError(f'{table}.{key}: 필수 값이 비었습니다.')
            continue
        kind = columns[key][0].upper()
        if kind in ('TEXT', 'VARCHAR') and not isinstance(value, str):
            raise ValueError(f'{table}.{key}: 문자열이 아닙니다.')
        if kind in ('INTEGER', 'BIGINT', 'BOOLEAN') and type(value) is not int:
            raise ValueError(f'{table}.{key}: 정수가 아닙니다.')
        if not isinstance(value, (str, int, float)):
            raise ValueError('DB 값 형식이 올바르지 않습니다.')


def canonical(raw, thread_id):
    result = records(raw, thread_id)
    header = result[0]['payload']
    header['cwd'] = '<mapped-project>'
    header.pop('runtime_workspace_roots', None)
    for obj in result:
        if obj['type'] == 'turn_context':
            for key in ('cwd', 'workspace_roots', 'approval_policy', 'approvals_reviewer', 'sandbox_policy', 'permission_profile'):
                obj['payload'].pop(key, None)
    return [digest(encoded(item)) for item in result]


def validate(snapshot):
    row = snapshot['data']['thread']
    validate_row(row, 'threads')
    thread_id = native_id(row['id'])
    result = records(snapshot['rollout'], thread_id)
    header = result[0]['payload']
    if snapshot['manifest'].get('engineVersion') not in VERSIONS:
        raise ValueError('Desktop 버전이 다릅니다. 두 PC에서 지원 버전을 사용하세요.')
    if not isinstance(header.get('cli_version'), str) or not 0 < len(header['cli_version']) <= 200:
        raise ValueError('세션의 생성 버전 정보가 올바르지 않습니다.')
    if row['history_mode'] not in ('paginated', 'legacy'):
        raise ValueError('지원하지 않는 이력 형식입니다.')
    if absolute(header.get('cwd', '')) != absolute(row['cwd']):
        raise ValueError('DB와 세션 헤더의 프로젝트 경로가 다릅니다.')
    roots = header.get('runtime_workspace_roots', [row['cwd']])
    if not isinstance(roots, list) or len(roots) > 100 or any(not isinstance(p, str) or not Path(p).is_absolute() for p in roots):
        raise ValueError('세션의 작업 폴더 목록이 올바르지 않습니다.')
    if header.get('dynamic_tools') or snapshot['data'].get('dynamicTools'):
        raise ValueError('동적 도구가 등록된 세션은 현재 이식 지원 범위 밖입니다.')
    expected = trusted_schema()
    if snapshot['manifest']['schema'] != expected:
        raise ValueError('보관 파일의 DB 구조가 지원 버전과 다릅니다.')
    tables = snapshot['data']['history']
    if set(tables) != set(TABLES):
        raise ValueError('이력 테이블 목록이 다릅니다.')
    for table, rows in tables.items():
        if len(rows) > 1000000:
            raise ValueError('선택 세션의 이력 행이 너무 많습니다.')
        for item in rows:
            validate_row(item, table)
            if item.get('thread_id') != thread_id:
                raise ValueError('다른 세션의 이력이 섞여 있습니다.')
            for key, value in item.items():
                if not isinstance(value, (str, int, float, type(None))):
                    raise ValueError('DB 값의 형식이 올바르지 않습니다.')
                if key in ('rollout_byte_offset', 'rollout_end_byte_offset', 'next_rollout_byte_offset'):
                    if value is not None and (type(value) is not int or not 0 <= value <= len(snapshot['rollout'])):
                        raise ValueError('이력 파일 위치가 범위를 벗어났습니다.')
    return thread_id


def selected(home, thread_id):
    check_schema(home)
    with ro(home / FILES[0]) as state:
        state.execute('BEGIN')
        found = state.execute('SELECT * FROM threads WHERE id=?', (thread_id,)).fetchone()
        if found is None:
            return None
        row = dict(found)
        tools = [dict(item) for item in state.execute('SELECT * FROM thread_dynamic_tools WHERE thread_id=? ORDER BY position', (thread_id,))]
    path = rollout_path(home, row['rollout_path'])
    if path.stat().st_size > LIMIT:
        raise ValueError('선택한 세션이 1GiB를 초과합니다.')
    raw = path.read_bytes()
    with ro(home / FILES[1]) as history:
        history.execute('BEGIN')
        tables = {table: [dict(item) for item in history.execute(
            f'SELECT * FROM {table} WHERE thread_id=? ORDER BY ' + ('thread_id' if table.endswith('state') else 'rollout_ordinal'),
            (thread_id,))] for table in TABLES}
    snapshot = {'manifest': {'format': 1, 'schema': trusted_schema(), 'engineVersion': VERSIONS[-1]},
        'data': {'thread': row, 'history': tables, 'dynamicTools': tools}, 'rollout': raw}
    validate(snapshot)
    return snapshot


def snapshot_hash(snapshot):
    if snapshot is None:
        return 'absent'
    return digest(encoded(snapshot['data']) + snapshot['rollout'])


def write_archive(snapshot, output):
    output = Path(output).absolute()
    no_reparse(output)
    manifest = copy.deepcopy(snapshot['manifest'])
    data = encoded(snapshot['data'])
    raw = snapshot['rollout']
    if len(data) + len(raw) > LIMIT:
        raise ValueError('선택한 세션 묶음이 1GiB를 초과합니다.')
    manifest['hashes'] = {'data.json': digest(data), 'rollout.jsonl': digest(raw)}
    with output.open('xb') as stream:
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('manifest.json', encoded(manifest))
            archive.writestr('data.json', data)
            archive.writestr('rollout.jsonl', raw)
        stream.flush()
        os.fsync(stream.fileno())


def read_archive(path):
    path = Path(path)
    with path.open('rb') as stream:
        sealed_bytes = stream.read(LIMIT + 1)
    if len(sealed_bytes) > LIMIT:
        raise ValueError('보관 파일 크기가 너무 큽니다.')
    with zipfile.ZipFile(io.BytesIO(sealed_bytes)) as archive:
        entries = archive.infolist()
        if len(entries) != 3 or {x.filename for x in entries} != {'manifest.json', 'data.json', 'rollout.jsonl'}:
            raise ValueError('보관 파일 항목이 올바르지 않습니다.')
        if sum(x.file_size for x in entries) > LIMIT or archive.getinfo('manifest.json').file_size > 1024*1024:
            raise ValueError('압축 해제 크기가 너무 큽니다.')
        manifest = json.loads(archive.read('manifest.json'))
        if manifest.get('format') != 1:
            raise ValueError('보관 파일 형식 버전이 다릅니다.')
        data, raw = archive.read('data.json'), archive.read('rollout.jsonl')
        if manifest['hashes'] != {'data.json': digest(data), 'rollout.jsonl': digest(raw)}:
            raise ValueError('보관 파일 내용 검증 실패')
        result = {'manifest': manifest, 'data': json.loads(data), 'rollout': raw, 'archiveHash': digest(sealed_bytes)}
    validate(result)
    return result


def summary(snapshot):
    if snapshot is None:
        return None
    row = snapshot['data']['thread']
    # 전송 메타데이터는 NUL·줄바꿈을 거부하므로 한 줄 제목으로 바꾼다.
    title = re.sub(r'[\x00\r\n]', ' ', (row['name'] or row['title'])[:1024])
    return {'id': row['id'], 'sessionId': row['id'], 'title': title, 'cwd': row['cwd'], 'sourceCwd': row['cwd'],
        'updatedAt': datetime.datetime.fromtimestamp(row['updated_at'], datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        'cliVersion': snapshot['manifest']['engineVersion'], 'historyMode': row['history_mode'],
        'recordCount': len(records(snapshot['rollout'], row['id']))}


def list_sessions(home, search='', offset=0, limit=200):
    if not 0 <= offset or not 1 <= limit <= 200:
        raise ValueError('목록 페이지 범위가 올바르지 않습니다.')
    with ro(home / FILES[0]) as db:
        search = '%' + search.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
        where = "WHERE title LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\' OR cwd LIKE ? ESCAPE '\\'"
        params = (search, search, search, search)
        db.execute('BEGIN')
        total = db.execute('SELECT COUNT(*) FROM threads ' + where, params).fetchone()[0]
        # 하위 에이전트 대화(source가 {"subagent":…})는 헤더 session_id가 부모 것이라 따로 내보낼 수 없다. 숨기지 않고 표시만 한다.
        rows = db.execute("SELECT id,SUBSTR(COALESCE(NULLIF(name,''),title),1,1024) AS title,cwd,updated_at AS updatedAt,history_mode AS historyMode,archived,"
            """source LIKE '{"subagent":%' AS subagent """
            'FROM threads ' + where + ' ORDER BY updated_at_ms DESC,id LIMIT ? OFFSET ?', (*params, limit, offset))
        # GUI 계약: updatedAt은 UTC RFC3339 문자열, archived·subagent는 bool.
        return {'total': total, 'sessions': [{**dict(row), 'archived': bool(row['archived']), 'subagent': bool(row['subagent']),
            'updatedAt': datetime.datetime.fromtimestamp(row['updatedAt'], datetime.timezone.utc).isoformat().replace('+00:00', 'Z')}
            for row in rows]}


def inspect(home, archive, cwd, engine=None):
    return inspect_loaded(home, read_archive(archive), cwd, engine)


def inspect_loaded(home, incoming, cwd, engine=None):
    cwd = absolute(cwd)
    no_reparse(cwd)
    if not cwd.is_dir():
        raise ValueError('가져올 작업 폴더가 없습니다.')
    check_schema(home, allow_missing=True)
    thread_id = validate(incoming)
    # 두 PC의 엔진 버전이 정확히 같을 때만 가져온다. CLI는 항상 이 PC 엔진 버전을 넘긴다(시험 호출만 None).
    if engine is not None and incoming['manifest']['engineVersion'] != engine:
        raise ValueError(f"백업한 PC의 Codex Desktop 엔진({incoming['manifest']['engineVersion']})과 "
            f'이 PC 엔진({engine})이 다릅니다. 두 PC를 같은 버전으로 맞춘 뒤 다시 백업하세요.')
    if all((home / name).exists() for name in FILES):
        current = selected(home, thread_id)
    elif (home / FILES[0]).exists():
        with ro(home / FILES[0]) as db:
            if db.execute('SELECT 1 FROM threads WHERE id=?', (thread_id,)).fetchone():
                raise ValueError('기존 세션의 이력 DB가 없습니다.')
        current = None
    else:
        current = None
    status = 'new'
    if current is not None:
        source = canonical(incoming['rollout'], thread_id)
        target = canonical(current['rollout'], thread_id)
        if source == target:
            status = 'equal'
        elif len(source) > len(target) and source[:len(target)] == target:
            status = 'incoming_newer'
        elif len(target) > len(source) and target[:len(source)] == source:
            status = 'local_newer'
        else:
            status = 'conflict'
    token = digest(encoded({'archive': incoming['archiveHash'], 'home': str(home),
        'cwd': str(cwd), 'baseline': snapshot_hash(current), 'status': status}))
    return {'status': status, 'reason': {'new': '처음 가져오는 세션', 'equal': '동일한 이력',
        'incoming_newer': '가져온 이력이 기존 이력의 연장', 'local_newer': '현재 PC 이력이 더 이어짐',
        'conflict': '같은 ID에서 기록이 갈라짐; 항목별 사용자 선택 필요'}[status],
        'token': token, 'source': summary(incoming), 'target': summary(current)}


def inspect_many(home, request, engine=None):
    if not isinstance(request, list) or not 1 <= len(request) <= 200:
        raise ValueError('한 번에 1~200개 항목을 비교하세요.')
    results = []
    keys = set()
    for job in request:
        if not isinstance(job, dict) or set(job) != {'key', 'archive', 'cwd'} or not isinstance(job['key'], str):
            raise ValueError('비교 요청 형식이 다릅니다.')
        if not 0 < len(job['key']) <= 256 or job['key'] in keys:
            raise ValueError('항목 식별자가 중복되거나 올바르지 않습니다.')
        keys.add(job['key'])
        try:
            result = inspect(home, job['archive'], job['cwd'], engine)
        except Exception as exc:
            result = {'status': 'blocked', 'reason': str(exc), 'token': None, 'source': None, 'target': None}
        results.append({'key': job['key'], **result, 'choice': 'skip'})
    return {'items': results}


# 스크립트 파일 대신 고정 명령으로 실행해 실행 정책 우회 옵션이 필요 없다. 이 파일의 SHA 고정에 함께 포함된다.
CLOSED_CHECK = r"""$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$writers=@(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(?i)(codex|codex-app|codex-code-mode-host|code-mode-host|ChatGPT|Code|Cursor|Windsurf)\.exe$' -or
    ($_.Name -eq 'node.exe' -and $_.CommandLine -match '(?i)(@openai[\\/]codex|[\\/]codex[\\/]bin[\\/]|codex.*app-server)')
})
if ($writers.Count) { [Console]::Out.Write('Codex/IDE writer PID: '+($writers.ProcessId -join ', ')); exit 1 }
exit 0"""


def assert_no_writers():
    if os.name != 'nt':
        raise ValueError('Windows에서만 실제 내보내기/가져오기를 실행할 수 있습니다.')
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand',
        base64.b64encode(CLOSED_CHECK.encode('utf-16-le')).decode()],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode != 0:
        raise ValueError('Codex 앱/CLI/IDE를 모두 종료하세요. ' + result.stdout.strip() + result.stderr.strip())


def assert_closed():
    assert_no_writers()
    return engine_version()


def engine_version():
    root = Path(os.environ.get('LOCALAPPDATA', '')) / 'OpenAI' / 'Codex' / 'bin'
    candidates = sorted(root.glob('*/codex.exe'), key=lambda p: p.stat().st_mtime_ns, reverse=True)
    if not candidates:
        raise ValueError('Codex Desktop 엔진을 찾지 못했습니다.')
    version = subprocess.run([str(candidates[0]), '--version'], capture_output=True,
        text=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
    engine = version.stdout.strip().removeprefix('codex-cli ')
    if version.returncode or engine not in VERSIONS or version.stdout.strip() != 'codex-cli ' + engine:
        raise ValueError('지원하는 Codex Desktop 엔진 버전과 다릅니다: ' + version.stdout.strip())
    return engine


def pending(home):
    root = home / '.ctxhop-desktop-recovery'
    no_reparse(root)
    return [p for p in root.glob('*/journal.json') if json.loads(p.read_text(encoding='utf-8'))['status'] == 'pending']


def save_json(path, obj):
    temp = path.with_suffix('.tmp')
    # 중단으로 남은 이전 임시 파일은 덮어쓴다. 'xb'면 복구 완료 기록이 영구히 실패한다.
    with temp.open('wb') as stream:
        stream.write(encoded(obj))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def mapped(snapshot, cwd, path, current):
    result = copy.deepcopy(snapshot)
    raw = result['rollout']
    row = result['data']['thread']
    row['cwd'], row['rollout_path'] = str(cwd), str(path)
    if current is not None:
        for key in LOCAL_FIELDS:
            row[key] = current['data']['thread'][key]
    else:
        for key in LOCAL_FIELDS:
            row[key] = None
        row.update(is_pinned=0, sandbox_policy='{"type":"read-only"}', approval_mode='untrusted',
            memory_mode='disabled', daybreak_enabled=0)
    lines = raw.splitlines(keepends=True)
    parsed = records(raw, row['id'])
    last_context = next((i for i in range(len(parsed)-1, -1, -1) if parsed[i]['type'] == 'turn_context'), None)
    parsed[0]['payload']['cwd'] = str(cwd)
    if 'runtime_workspace_roots' in parsed[0]['payload']:
        parsed[0]['payload']['runtime_workspace_roots'] = [str(cwd)]
    changes = {0: encoded(parsed[0]) + b'\n'}
    if last_context is not None:
        context = parsed[last_context]['payload']
        context['cwd'], context['workspace_roots'] = str(cwd), [str(cwd)]
        if current is not None:
            prior_context = next((obj['payload'] for obj in reversed(records(current['rollout'], row['id']))
                if obj['type'] == 'turn_context'), None)
        else:
            prior_context = None
        for key in ('approval_policy', 'approvals_reviewer', 'sandbox_policy', 'permission_profile'):
            context.pop(key, None)
            if prior_context is not None and key in prior_context:
                context[key] = copy.deepcopy(prior_context[key])
        if prior_context is None:
            context.update(approval_policy='untrusted', approvals_reviewer='user', sandbox_policy={'type': 'read-only'},
                permission_profile={'type': 'managed', 'file_system': {'type': 'restricted', 'entries': [
                    {'path': {'type': 'special', 'value': {'kind': 'root'}}, 'access': 'read'}]}, 'network': 'restricted'})
        changes[last_context] = encoded(parsed[last_context]) + b'\n'
    spans = []
    old_at, new_at = 0, 0
    new_lines = []
    for index, line in enumerate(lines):
        replacement = changes.get(index, line)
        spans.append((old_at, old_at+len(line), new_at, new_at+len(replacement), index in changes))
        old_at += len(line)
        new_at += len(replacement)
        new_lines.append(replacement)
    def map_offset(value):
        if value is None:
            return None
        for old_start, old_end, new_start, new_end, changed in spans:
            if value == old_start:
                return new_start
            if value == old_end:
                return new_end
            if old_start < value < old_end:
                if changed:
                    raise ValueError('이력 위치가 변경되는 메타데이터 레코드 내부를 가리킵니다.')
                return value + new_start - old_start
        raise ValueError('이력 위치를 재매핑할 수 없습니다.')
    result['rollout'] = b''.join(new_lines)
    for rows in result['data']['history'].values():
        for item in rows:
            for key in ('rollout_byte_offset', 'rollout_end_byte_offset', 'next_rollout_byte_offset'):
                if key in item:
                    item[key] = map_offset(item[key])
    validate(result)
    return result


def replace_rows(db, snapshot):
    row = snapshot['data']['thread']
    thread_id = row['id']
    for table in TABLES:
        db.execute(f'DELETE FROM history.{table} WHERE thread_id=?', (thread_id,))
        for item in snapshot['data']['history'][table]:
            columns = list(item)
            db.execute(f'INSERT INTO history.{table} ({",".join(columns)}) VALUES ({",".join("?" for x in columns)})', list(item.values()))
    columns = list(row)
    db.execute(f'INSERT INTO threads ({",".join(columns)}) VALUES ({",".join("?" for x in columns)}) '
        'ON CONFLICT(id) DO UPDATE SET ' + ','.join(f'{x}=excluded.{x}' for x in columns if x != 'id'), list(row.values()))


def apply(home, archive, cwd, token, choice, guard=None, failpoint=None):
    if choice == 'skip':
        return {'status': 'skipped'}
    if choice != 'incoming':
        raise ValueError('항목 선택이 올바르지 않습니다.')
    guard = guard or assert_closed
    engine = guard()
    if pending(home):
        raise ValueError('중단된 가져오기를 먼저 복구하세요.')
    incoming = read_archive(archive)
    # 실제 guard는 이 PC 엔진 버전을 돌려주고, inspect_loaded가 백업 엔진 버전과 정확히 비교한다.
    preview = inspect_loaded(home, incoming, cwd, engine)
    if token != preview['token']:
        raise ValueError('미리보기 뒤 데이터가 바뀌었습니다. 다시 비교하고 선택하세요.')
    if preview['status'] in ('equal', 'local_newer'):
        return {'status': preview['status']}
    thread_id = validate(incoming)
    current = selected(home, thread_id) if all((home / name).exists() for name in FILES) else None
    if current is not None:
        path = rollout_path(home, current['data']['thread']['rollout_path'])
    else:
        date = datetime.datetime.fromtimestamp(incoming['data']['thread']['created_at'], datetime.timezone.utc)
        bucket = 'archived_sessions' if incoming['data']['thread']['archived'] else 'sessions'
        path = rollout_path(home, home / bucket / date.strftime('%Y/%m/%d') / f'rollout-{date:%Y-%m-%dT%H-%M-%S}-{thread_id}.jsonl')
        if path.exists():
            raise ValueError('등록되지 않은 같은 이름의 파일이 있습니다.')
    replacement = mapped(incoming, absolute(cwd), path, current)
    run = home / '.ctxhop-desktop-recovery' / uuid.uuid4().hex
    no_reparse(run)
    run.mkdir(parents=True)
    if current is not None:
        if engine:
            # 복구 사본으로 되살릴 때(inspect → apply) 이 PC 엔진과 비교되므로 실제 버전을 기록한다.
            current['manifest']['engineVersion'] = engine
        write_archive(current, run / 'before.zip')
    write_archive(replacement, run / 'incoming.zip')
    journal = {'status': 'pending', 'home': str(home), 'id': thread_id, 'path': str(path),
        'before': snapshot_hash(current), 'after': snapshot_hash(replacement),
        'beforeData': digest(encoded(current['data'])) if current is not None else None,
        'afterData': digest(encoded(replacement['data'])),
        'beforeFile': digest(current['rollout']) if current is not None else None,
        'afterFile': digest(replacement['rollout']), 'createdDb': [name for name in FILES if not (home / name).exists()]}
    save_json(run / 'journal.json', journal)
    for name in journal['createdDb']:
        create_database(home / name, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = run / 'rollout.stage'
    with stage.open('xb') as stream:
        stream.write(replacement['rollout'])
        stream.flush()
        os.fsync(stream.fileno())
    with sqlite3.connect(home / FILES[0], timeout=10) as db:
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA synchronous=FULL')
        db.execute('ATTACH DATABASE ? AS history', (str(home / FILES[1]),))
        db.execute('PRAGMA history.synchronous=FULL')
        db.execute('BEGIN IMMEDIATE')
        # 실제 반영 직전에도 writer와 미리보기 기준을 재확인한다.
        guard()
        if token != inspect(home, archive, cwd, engine)['token']:
            raise ValueError('적용 직전에 데이터가 바뀌었습니다.')
        replace_rows(db, replacement)
        os.replace(stage, path)
        if failpoint:
            failpoint('file')
        db.commit()
        if failpoint:
            failpoint('commit')
    journal['status'] = 'complete'
    save_json(run / 'journal.json', journal)
    return {'status': 'imported', 'id': thread_id, 'recovery': str(run), 'replaced': current is not None}


def database_data(home, thread_id):
    with ro(home / FILES[0]) as db:
        row = db.execute('SELECT * FROM threads WHERE id=?', (thread_id,)).fetchone()
        tools = [dict(x) for x in db.execute('SELECT * FROM thread_dynamic_tools WHERE thread_id=? ORDER BY position', (thread_id,))]
    with ro(home / FILES[1]) as db:
        history = {table: [dict(x) for x in db.execute(f'SELECT * FROM {table} WHERE thread_id=? ORDER BY ' +
            ('thread_id' if table.endswith('state') else 'rollout_ordinal'), (thread_id,))] for table in TABLES}
    return {'thread': dict(row) if row else None, 'history': history, 'dynamicTools': tools}


def recover(home, run, guard=None):
    # 이 PC의 이전 상태로 되돌리는 작업이라 엔진 버전 대신 고정 DB 구조(check_schema)로 호환을 확인한다.
    # 엔진이 업데이트돼도 구조가 같으면 복구할 수 있고, 구조가 바뀌었으면 아래에서 멈춘다.
    guard = guard or assert_no_writers
    guard()
    run = absolute(run)
    no_reparse(run)
    if run.parent != home / '.ctxhop-desktop-recovery' or not re.fullmatch('[a-f0-9]{32}', run.name):
        raise ValueError('이 저장소의 복구 작업 폴더를 선택하세요.')
    journal = json.loads((run / 'journal.json').read_text(encoding='utf-8'))
    if journal['status'] != 'pending' or journal['home'] != str(home):
        raise ValueError('이 저장소의 중단된 작업이 아닙니다.')
    incoming = read_archive(run / 'incoming.zip')
    before = read_archive(run / 'before.zip') if journal['before'] != 'absent' else None
    if snapshot_hash(incoming) != journal['after'] or snapshot_hash(before) != journal['before']:
        raise ValueError('복구 원본 검증 실패')
    thread_id = validate(incoming)
    if journal['id'] != thread_id or before is not None and validate(before) != thread_id:
        raise ValueError('복구 세션 ID가 다릅니다.')
    path = rollout_path(home, journal['path'])
    if path != rollout_path(home, incoming['data']['thread']['rollout_path']):
        raise ValueError('복구 파일 경로가 다릅니다.')
    check_schema(home, allow_missing=True)
    for name in FILES:
        if not (home / name).exists():
            if name not in journal['createdDb']:
                raise ValueError('기존 DB가 없어졌습니다.')
            create_database(home / name, name)
    empty = {'thread': None, 'history': {table: [] for table in TABLES}, 'dynamicTools': []}
    baseline = before['data'] if before else empty
    def check():
        data = database_data(home, thread_id)
        if data['thread'] not in (baseline['thread'], incoming['data']['thread']):
            raise ValueError('중단 뒤 세션 메타데이터가 변경됐습니다. 자동 복구를 중단합니다.')
        if data['dynamicTools'] != baseline['dynamicTools']:
            raise ValueError('중단 뒤 도구 설정이 변경됐습니다.')
        for table in TABLES:
            if data['history'][table] not in (baseline['history'][table], incoming['data']['history'][table]):
                raise ValueError('중단 뒤 세션 이력이 변경됐습니다. 자동 복구를 중단합니다.')
        file_hash = digest(path.read_bytes()) if path.exists() else None
        if file_hash not in (journal['beforeFile'], journal['afterFile']):
            raise ValueError('중단 뒤 세션 파일이 변경됐습니다. 자동 복구를 중단합니다.')
        if before is None:
            with ro(home / FILES[0]) as db:
                if db.execute('SELECT 1 FROM thread_attachments WHERE thread_id=?', (thread_id,)).fetchone() or db.execute(
                        'SELECT 1 FROM thread_spawn_edges WHERE parent_thread_id=? OR child_thread_id=?', (thread_id,thread_id)).fetchone():
                    raise ValueError('새 세션에 다른 작업이 연결됐습니다. 자동 삭제를 중단합니다.')
    check()
    if before:
        stage = run / 'undo'
        no_reparse(stage)
        if stage.exists():
            if digest(stage.read_bytes()) != journal['beforeFile']:
                raise ValueError('복구 임시 파일이 변경됐습니다.')
        else:
            with stage.open('xb') as stream:
                stream.write(before['rollout'])
                stream.flush()
                os.fsync(stream.fileno())
    with sqlite3.connect(home / FILES[0], timeout=10) as db:
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('ATTACH DATABASE ? AS history', (str(home / FILES[1]),))
        db.execute('BEGIN IMMEDIATE')
        guard()
        check_schema(home)  # 엔진 버전을 보지 않으므로 쓰기 잠금 안에서 구조를 다시 확인한다.
        check()
        if before:
            replace_rows(db, before)
            os.replace(stage, path)
        else:
            for table in TABLES:
                db.execute(f'DELETE FROM history.{table} WHERE thread_id=?', (thread_id,))
            db.execute('DELETE FROM threads WHERE id=?', (thread_id,))
        db.commit()
    if before is None and path.exists():
        path.unlink()  # 확인한 선택 세션 파일 하나만 삭제. 복구 기록과 DB는 보존.
    journal['status'] = 'rolled_back'
    save_json(run / 'journal.json', journal)
    return {'status': 'rolled_back', 'id': thread_id, 'recovery': str(run)}


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('list', 'export', 'inspect', 'inspect-many', 'apply', 'recover', 'pending'))
    parser.add_argument('--home', required=True)
    parser.add_argument('--id')
    parser.add_argument('--archive')
    parser.add_argument('--cwd')
    parser.add_argument('--output')
    parser.add_argument('--run')
    parser.add_argument('--request')
    parser.add_argument('--search', default='')
    parser.add_argument('--offset', type=int, default=0)
    parser.add_argument('--limit', type=int, default=200)
    parser.add_argument('--token')
    parser.add_argument('--choice', choices=('skip', 'incoming'), default='skip')
    args = parser.parse_args()
    try:
        if sys.version_info < (3, 10):
            raise ValueError('Python 3.10 이상이 필요합니다.')
        home = check_home(args.home)
        if args.action == 'list':
            result = list_sessions(home, args.search, args.offset, args.limit)
        elif args.action == 'export':
            engine = assert_closed()
            if pending(home):
                raise ValueError('중단된 가져오기를 먼저 복구하세요.')
            snapshot = selected(home, native_id(args.id))
            if snapshot is None:
                raise ValueError('선택한 세션이 없습니다.')
            snapshot['manifest']['engineVersion'] = engine
            write_archive(snapshot, args.output)
            assert_closed()
            if snapshot_hash(selected(home, native_id(args.id))) != snapshot_hash(snapshot):
                raise ValueError('내보내는 동안 선택한 세션이 변경됐습니다. 생성 파일을 사용하지 마세요.')
            info = summary(snapshot)
            result = {'status': 'exported', 'metadata': {key: info[key] for key in
                ('sessionId', 'title', 'sourceCwd', 'updatedAt', 'historyMode', 'cliVersion', 'recordCount')},
                'session': info,
                'sha256': digest(Path(args.output).read_bytes()), 'bytes': Path(args.output).stat().st_size}
        elif args.action == 'inspect':
            result = inspect(home, args.archive, args.cwd, engine_version())
        elif args.action == 'inspect-many':
            path = Path(args.request)
            if path.stat().st_size > 1024*1024:
                raise ValueError('비교 요청 파일이 너무 큽니다.')
            result = inspect_many(home, json.loads(path.read_text(encoding='utf-8')), engine_version())
        elif args.action == 'pending':
            result = {'pending': [str(p.parent) for p in pending(home)]}
        elif args.action == 'recover':
            result = recover(home, args.run)
        else:
            result = apply(home, args.archive, args.cwd, args.token, args.choice)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as exc:
        result = {'status': 'blocked', 'reason': str(exc), 'token': None}
        if args.action == 'apply':
            # 중단된 가져오기의 복구 기록 위치를 GUI 오류와 함께 보여 준다.
            with contextlib.suppress(Exception):
                result['pending'] = [str(p.parent) for p in pending(check_home(args.home))]
        print(json.dumps(result, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
