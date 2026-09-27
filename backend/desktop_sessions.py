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
import time
import uuid
import zipfile
from pathlib import Path

# 아래 DB 구조(schema.json)와 격리 native 시험을 통과한 Desktop 엔진 빌드만 허용한다.
VERSIONS = ('0.158.0-alpha.2', '0.158.0-alpha.2.1')
SCHEMA_HASH = 'd24acac2105569b5b9cfdabc5259db8217b9a9f175d7d2b57a09a2d4f76fa0a2'
FILES = ('state_5.sqlite', 'thread_history_1.sqlite')
TABLES = ('thread_turns', 'thread_items', 'thread_history_projection_state', 'thread_realtime_items')
LIMIT = 1024 * 1024 * 1024
MAX_MEMBERS = 2000  # 한 묶음(부모 + 모든 하위 에이전트 대화)의 최대 대화 수
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


def records(raw, thread_id, sessions=()):
    # 하위 에이전트 대화의 헤더 session_id는 부모나 최상위 대화 ID다. sessions는 그 조상 ID들이다.
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
    if header['payload'].get('session_id', thread_id) not in (thread_id, *sessions):
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


def canonical(raw, thread_id, sessions=()):
    result = records(raw, thread_id, sessions)
    header = result[0]['payload']
    header['cwd'] = '<mapped-project>'
    header.pop('runtime_workspace_roots', None)
    for obj in result:
        if obj['type'] == 'turn_context':
            for key in ('cwd', 'workspace_roots', 'approval_policy', 'approvals_reviewer', 'sandbox_policy', 'permission_profile'):
                obj['payload'].pop(key, None)
    return [digest(encoded(item)) for item in result]


def validate_member(member, sessions=()):
    """묶음의 대화 하나(DB 행·이력·세션 파일)를 검사하고 세션 헤더를 돌려준다. sessions는 조상 대화 ID다."""
    row = member['data']['thread']
    validate_row(row, 'threads')
    thread_id = native_id(row['id'])
    header = records(member['rollout'], thread_id, sessions)[0]['payload']
    if not isinstance(header.get('cli_version'), str) or not 0 < len(header['cli_version']) <= 200:
        raise ValueError('세션의 생성 버전 정보가 올바르지 않습니다.')
    if row['history_mode'] not in ('paginated', 'legacy'):
        raise ValueError('지원하지 않는 이력 형식입니다.')
    if absolute(header.get('cwd', '')) != absolute(row['cwd']):
        raise ValueError('DB와 세션 헤더의 프로젝트 경로가 다릅니다.')
    roots = header.get('runtime_workspace_roots', [row['cwd']])
    if not isinstance(roots, list) or len(roots) > 100 or any(not isinstance(p, str) or not Path(p).is_absolute() for p in roots):
        raise ValueError('세션의 작업 폴더 목록이 올바르지 않습니다.')
    if header.get('dynamic_tools') or member['data'].get('dynamicTools'):
        raise ValueError('동적 도구가 등록된 세션은 현재 이식 지원 범위 밖입니다.')
    tables = member['data']['history']
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
                    if value is not None and (type(value) is not int or not 0 <= value <= len(member['rollout'])):
                        raise ValueError('이력 파일 위치가 범위를 벗어났습니다.')
    return header


def is_subagent(source):
    return source.startswith('{"subagent":')


def ancestors(family):
    """대화 ID마다 조상 ID 목록(부모부터 최상위까지)."""
    ids = [member['data']['thread']['id'] for member in family['members']]
    parents = {}
    for edge in family['edges']:
        if not isinstance(edge, dict) or set(edge) != {'parent_thread_id', 'child_thread_id', 'status'} or \
                not all(isinstance(value, str) for value in edge.values()):
            raise ValueError('하위 대화 연결 형식이 올바르지 않습니다.')
        if edge['child_thread_id'] in parents:
            raise ValueError('하위 대화 연결이 중복됐습니다.')
        parents[edge['child_thread_id']] = edge['parent_thread_id']
    if set(parents) != set(ids[1:]) or any(parent not in ids for parent in parents.values()):
        raise ValueError('하위 대화 연결이 묶음과 맞지 않습니다.')
    result = {}
    for thread_id in ids:
        chain, node = [], thread_id
        while node != ids[0]:
            node = parents[node]
            if node == thread_id or node in chain:
                raise ValueError('하위 대화 연결에 순환이 있습니다.')
            chain.append(node)
        result[thread_id] = chain
    return result


def validate_family(family):
    """묶음 전체를 검사하고 최상위 대화 ID를 돌려준다. 첫 대화가 최상위이고, 나머지는 thread_spawn_edges로 이어진 하위 에이전트 대화다."""
    manifest = family['manifest']
    if manifest.get('engineVersion') not in VERSIONS:
        raise ValueError('Desktop 버전이 다릅니다. 두 PC에서 지원 버전을 사용하세요.')
    if manifest['schema'] != trusted_schema():
        raise ValueError('보관 파일의 DB 구조가 지원 버전과 다릅니다.')
    members = family['members']
    if not isinstance(members, list) or not 1 <= len(members) <= MAX_MEMBERS or not isinstance(family['edges'], list):
        raise ValueError('대화 묶음 구성이 올바르지 않습니다.')
    ids = []
    for member in members:
        validate_row(member['data']['thread'], 'threads')
        ids.append(native_id(member['data']['thread']['id']))
    if len(set(ids)) != len(ids):
        raise ValueError('대화 묶음에 같은 대화가 두 번 있습니다.')
    if is_subagent(members[0]['data']['thread']['source']):
        raise ValueError('하위 에이전트 대화는 부모 대화와 함께 옮깁니다. 부모 대화를 선택하세요.')
    chains = ancestors(family)
    total = 0
    for member, thread_id in zip(members, ids):
        header = validate_member(member, chains[thread_id])
        if thread_id != ids[0]:
            if not is_subagent(member['data']['thread']['source']):
                raise ValueError('하위 대화가 아닌 기록이 묶음에 섞였습니다.')
            if header.get('parent_thread_id') != chains[thread_id][0]:
                raise ValueError('하위 대화 헤더의 부모가 연결 정보와 다릅니다.')
        total += len(encoded(member['data'])) + len(member['rollout'])
    if total > LIMIT:
        raise ValueError('선택한 대화 묶음이 1GiB를 초과합니다.')
    return ids[0]


def member(home, thread_id):
    """이 PC의 대화 하나(DB 행·이력·세션 파일). 없으면 None."""
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
    return {'data': {'thread': row, 'history': tables, 'dynamicTools': tools}, 'rollout': raw}


def family_edges(db, root):
    """root에서 thread_spawn_edges를 따라간 모든 하위 연결(부모가 먼저 나오는 순서)."""
    ids, edges, queue = {root}, [], [root]
    while queue:
        parent = queue.pop(0)
        for row in db.execute('SELECT parent_thread_id,child_thread_id,status FROM thread_spawn_edges '
                'WHERE parent_thread_id=? ORDER BY child_thread_id', (parent,)):
            if row['child_thread_id'] in ids:
                raise ValueError('하위 대화 연결에 순환이 있습니다.')
            ids.add(row['child_thread_id'])
            if len(ids) > MAX_MEMBERS:
                raise ValueError('하위 대화가 너무 많습니다.')
            edges.append(dict(row))
            queue.append(row['child_thread_id'])
    return edges


def selected(home, thread_id):
    """이 PC의 대화와 그 모든 하위 에이전트 대화를 한 묶음으로 읽는다. 없으면 None."""
    check_schema(home)
    with ro(home / FILES[0]) as state:
        state.execute('BEGIN')
        found = state.execute('SELECT source FROM threads WHERE id=?', (thread_id,)).fetchone()
        if found is None:
            return None
        if is_subagent(found['source']):
            raise ValueError('하위 에이전트 대화는 부모 대화와 함께 옮깁니다. 부모 대화를 선택하세요.')
        edges = family_edges(state, thread_id)
    members = [member(home, x) for x in [thread_id] + [edge['child_thread_id'] for edge in edges]]
    if any(item is None for item in members):
        raise ValueError('하위 대화 기록이 DB에 없습니다.')
    family = {'manifest': {'format': 2, 'schema': trusted_schema(), 'engineVersion': VERSIONS[-1]},
        'members': members, 'edges': edges}
    validate_family(family)
    return family


PATCH_FILE = re.compile(r'^\*\*\* (?:Update|Add|Delete) File: (.+)$', re.M)
ABSOLUTE = re.compile(r'^(?:[A-Za-z]:[\\/]|\\\\)')


def texts(value):
    """레코드 안의 모든 문자열. function_call arguments처럼 JSON 문자열 안에 JSON이 한 번 더 들어 있으면 끝까지 푼다."""
    if isinstance(value, dict):
        for item in value.values():
            yield from texts(item)
    elif isinstance(value, list):
        for item in value:
            yield from texts(item)
    elif isinstance(value, str):
        if value[:1] in ('{', '['):
            try:
                yield from texts(json.loads(value))
                return
            except ValueError:
                pass
        yield value


def work_folders(family):
    """묶음이 작업한 폴더(대화와 턴마다 기록된 cwd, 처음 본 순서)와 패치가 절대 경로로 고친 파일. 합치고 거르는 일은 GUI가 한다."""
    cwds, edits = [], []
    for item in family['members']:
        if item['data']['thread']['cwd'] not in cwds:
            cwds.append(item['data']['thread']['cwd'])
        for line in item['rollout'].splitlines():
            if b'turn_context' not in line and b'File: ' not in line:
                continue
            obj = json.loads(line)
            payload = obj['payload']
            if obj.get('type') == 'turn_context' and isinstance(payload.get('cwd'), str) and payload['cwd'] not in cwds:
                cwds.append(payload['cwd'])
            for text in texts(payload):
                for match in PATCH_FILE.finditer(text):
                    path = match.group(1).strip()
                    if ABSOLUTE.match(path) and path not in edits:
                        edits.append(path)
    return {'cwds': cwds, 'edits': edits[:1000]}  # ponytail: 폴더 밖 편집 목록은 보여 주기용이라 1000개에서 자른다


def member_hash(item):
    return digest(encoded(item['data']) + item['rollout'])


def snapshot_hash(family):
    if family is None:
        return 'absent'
    return digest(encoded({'members': [member_hash(item) for item in family['members']], 'edges': family['edges']}))


def iso(seconds):
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')


def seal(output, manifest, files):
    output = Path(output).absolute()
    no_reparse(output)
    if sum(len(raw) for raw in files.values()) > LIMIT:
        raise ValueError('선택한 대화 묶음이 1GiB를 초과합니다.')
    manifest = {**manifest, 'hashes': {name: digest(raw) for name, raw in files.items()}}
    with output.open('xb') as stream:
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('manifest.json', encoded(manifest))
            for name, raw in files.items():
                archive.writestr(name, raw)
        stream.flush()
        os.fsync(stream.fileno())


def write_archive(family, output):
    """묶음 보관 파일(형식 2): manifest.json, data.json(대화별 DB 자료와 하위 연결), rollouts/NNNN.jsonl(대화별 세션 파일)."""
    members = family['members']
    files = {'data.json': encoded({'members': [item['data'] for item in members], 'edges': family['edges']})}
    for index, item in enumerate(members):
        files[f'rollouts/{index:04d}.jsonl'] = item['rollout']
    seal(output, {'format': 2, 'schema': family['manifest']['schema'], 'engineVersion': family['manifest']['engineVersion']}, files)


def write_member_archive(item, engine, sessions, output):
    """복구 폴더에 남기는 대화 하나(형식 1). sessions는 하위 대화 헤더 검사에 쓰는 조상 ID다."""
    seal(output, {'format': 1, 'schema': trusted_schema(), 'engineVersion': engine, 'sessions': list(sessions)},
        {'data.json': encoded(item['data']), 'rollout.jsonl': item['rollout']})


def unpack(path):
    with Path(path).open('rb') as stream:
        sealed_bytes = stream.read(LIMIT + 1)
    if len(sealed_bytes) > LIMIT:
        raise ValueError('보관 파일 크기가 너무 큽니다.')
    with zipfile.ZipFile(io.BytesIO(sealed_bytes)) as archive:
        entries = archive.infolist()
        names = [x.filename for x in entries]
        if len(set(names)) != len(names) or 'manifest.json' not in names or len(names) > MAX_MEMBERS + 2:
            raise ValueError('보관 파일 항목이 올바르지 않습니다.')
        if sum(x.file_size for x in entries) > LIMIT or archive.getinfo('manifest.json').file_size > 1024*1024:
            raise ValueError('압축 해제 크기가 너무 큽니다.')
        files = {name: archive.read(name) for name in names}
    manifest = json.loads(files.pop('manifest.json'))
    if not isinstance(manifest, dict) or manifest.get('format') not in (1, 2):
        raise ValueError('보관 파일 형식 버전이 다릅니다.')
    if manifest.get('hashes') != {name: digest(raw) for name, raw in files.items()}:
        raise ValueError('보관 파일 내용 검증 실패')
    return manifest, files, digest(sealed_bytes)


def read_archive(path):
    """보관 파일을 묶음으로 읽는다. 형식 1(이전 판의 대화 하나)과 형식 2(대화 묶음)를 모두 읽는다."""
    manifest, files, sealed = unpack(path)
    if set(manifest) != {'format', 'schema', 'engineVersion', 'hashes'}:
        raise ValueError('보관 파일 항목이 올바르지 않습니다.')
    if manifest['format'] == 1:
        if set(files) != {'data.json', 'rollout.jsonl'}:
            raise ValueError('보관 파일 항목이 올바르지 않습니다.')
        family = {'members': [{'data': json.loads(files['data.json']), 'rollout': files['rollout.jsonl']}], 'edges': []}
    else:
        data = json.loads(files.get('data.json', b'null'))
        if not isinstance(data, dict) or set(data) != {'members', 'edges'} or not isinstance(data['members'], list) or \
                not 1 <= len(data['members']) <= MAX_MEMBERS:
            raise ValueError('보관 파일 항목이 올바르지 않습니다.')
        names = [f'rollouts/{index:04d}.jsonl' for index in range(len(data['members']))]
        if set(files) != {'data.json', *names}:
            raise ValueError('보관 파일 항목이 올바르지 않습니다.')
        family = {'members': [{'data': item, 'rollout': files[name]} for item, name in zip(data['members'], names)],
            'edges': data['edges']}
    family['manifest'] = manifest
    family['archiveHash'] = sealed
    validate_family(family)
    return family


def read_member_archive(path):
    """복구 폴더의 대화 하나. 이전 판의 복구 기록(before.zip, incoming.zip)도 읽는다."""
    manifest, files, _ = unpack(path)
    if manifest['format'] != 1 or set(manifest) - {'sessions'} != {'format', 'schema', 'engineVersion', 'hashes'} or \
            set(files) != {'data.json', 'rollout.jsonl'}:
        raise ValueError('복구 파일 항목이 올바르지 않습니다.')
    if manifest['engineVersion'] not in VERSIONS or manifest['schema'] != trusted_schema():
        raise ValueError('복구 파일의 버전이나 DB 구조가 다릅니다.')
    sessions = manifest.get('sessions', [])
    if not isinstance(sessions, list) or len(sessions) > MAX_MEMBERS:
        raise ValueError('복구 파일의 조상 대화 목록이 올바르지 않습니다.')
    item = {'data': json.loads(files['data.json']), 'rollout': files['rollout.jsonl']}
    validate_member(item, [native_id(x) for x in sessions])
    return item


def summary(family):
    if family is None:
        return None
    root = family['members'][0]
    row = root['data']['thread']
    # 전송 메타데이터는 NUL·줄바꿈을 거부하므로 한 줄 제목으로 바꾼다.
    title = re.sub(r'[\x00\r\n]', ' ', (row['name'] or row['title'])[:1024])
    children = len(family['members']) - 1
    # 형식 2 백업은 historyMode 끝에 ;family=하위 대화 수를 붙여, 하위 대화가 빠진 이전 백업과 구분한다.
    mode = row['history_mode'] + (f';family={children}' if family['manifest']['format'] == 2 else '')
    return {'id': row['id'], 'sessionId': row['id'], 'title': title, 'cwd': row['cwd'], 'sourceCwd': row['cwd'],
        'updatedAt': iso(max(item['data']['thread']['updated_at'] for item in family['members'])),
        'cliVersion': family['manifest']['engineVersion'], 'historyMode': mode,
        'recordCount': len(records(root['rollout'], row['id'])), 'children': children}


FAMILY_SQL = ('WITH RECURSIVE family(id) AS (SELECT ? UNION SELECT e.child_thread_id FROM thread_spawn_edges e '
    'JOIN family f ON e.parent_thread_id=f.id) SELECT COUNT(*)-1, MAX(t.updated_at) FROM family f JOIN threads t ON t.id=f.id')


def list_sessions(home, search='', offset=0, limit=200):
    if not 0 <= offset or not 1 <= limit <= 200:
        raise ValueError('목록 페이지 범위가 올바르지 않습니다.')
    with ro(home / FILES[0]) as db:
        search = '%' + search.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
        # 하위 에이전트 대화(source가 {"subagent":…})는 부모 대화와 함께 옮기므로 목록에 따로 싣지 않는다.
        where = ("WHERE source NOT LIKE '{\"subagent\":%' AND (title LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\' "
            "OR id LIKE ? ESCAPE '\\' OR cwd LIKE ? ESCAPE '\\')")
        params = (search, search, search, search)
        db.execute('BEGIN')
        total = db.execute('SELECT COUNT(*) FROM threads ' + where, params).fetchone()[0]
        rows = db.execute("SELECT id,SUBSTR(COALESCE(NULLIF(name,''),title),1,1024) AS title,cwd,history_mode AS historyMode,archived "
            'FROM threads ' + where + ' ORDER BY updated_at_ms DESC,id LIMIT ? OFFSET ?', (*params, limit, offset)).fetchall()
        sessions = []
        for row in rows:
            children, updated = db.execute(FAMILY_SQL, (row['id'],)).fetchone()
            # GUI 계약: updatedAt은 묶음에서 가장 늦은 수정 시각(UTC RFC3339), archived는 bool, children은 하위 대화 수.
            sessions.append({**dict(row), 'archived': bool(row['archived']), 'children': children, 'updatedAt': iso(updated)})
        return {'total': total, 'sessions': sessions}


def inspect(home, archive, cwd, engine=None):
    return inspect_loaded(home, read_archive(archive), cwd, engine)


REASONS = {'new': '처음 가져오는 세션', 'equal': '동일한 이력', 'incoming_newer': '가져온 이력이 기존 이력의 연장',
    'local_newer': '현재 PC 이력이 더 이어짐', 'conflict': '같은 ID에서 기록이 갈라짐; 항목별 사용자 선택 필요'}
CHILD_LABELS = (('new', '새로'), ('incoming_newer', '이어짐'), ('conflict', '갈라짐'), ('local_newer', '이 PC가 더 최신'),
    ('local_only', '이 PC에만'))
WRITE = ('new', 'incoming_newer', 'conflict')


def history_status(source, target):
    if source == target:
        return 'equal'
    if len(source) > len(target) and source[:len(target)] == target:
        return 'incoming_newer'
    if len(target) > len(source) and target[:len(source)] == source:
        return 'local_newer'
    return 'conflict'


def compare(home, incoming, cwd, engine=None):
    """이 PC의 같은 묶음과 비교한다. (미리보기 결과, 이 PC 묶음 또는 None, 대화 ID별 상태)를 돌려준다."""
    cwd = absolute(cwd)
    no_reparse(cwd)
    if not cwd.is_dir():
        raise ValueError('가져올 작업 폴더가 없습니다.')
    check_schema(home, allow_missing=True)
    root = validate_family(incoming)
    # 두 PC의 엔진 버전이 정확히 같을 때만 가져온다. CLI는 항상 이 PC 엔진 버전을 넘긴다(시험 호출만 None).
    if engine is not None and incoming['manifest']['engineVersion'] != engine:
        raise ValueError(f"백업한 PC의 Codex Desktop 엔진({incoming['manifest']['engineVersion']})과 "
            f'이 PC 엔진({engine})이 다릅니다. 두 PC를 같은 버전으로 맞춘 뒤 다시 백업하세요.')
    ids = [item['data']['thread']['id'] for item in incoming['members']]
    found = set()
    if (home / FILES[0]).exists():
        with ro(home / FILES[0]) as db:
            db.execute('BEGIN')
            found = {x for x in ids if db.execute('SELECT 1 FROM threads WHERE id=?', (x,)).fetchone()}
    current = None
    if found:
        if not (home / FILES[1]).exists():
            raise ValueError('기존 세션의 이력 DB가 없습니다.')
        current = selected(home, root)
    local = {item['data']['thread']['id']: item for item in current['members']} if current else {}
    if found - set(local):
        raise ValueError('가져올 하위 대화가 이 PC에서 다른 대화에 연결돼 있습니다.')
    chains = ancestors(incoming)
    local_chains = ancestors(current) if current else {}
    statuses = {}
    for item, thread_id in zip(incoming['members'], ids):
        before = local.get(thread_id)
        if before is None:
            statuses[thread_id] = 'new'
            continue
        if local_chains[thread_id] != chains[thread_id]:
            raise ValueError('하위 대화 연결이 두 PC에서 다릅니다.')
        statuses[thread_id] = history_status(canonical(item['rollout'], thread_id, chains[thread_id]),
            canonical(before['rollout'], thread_id, chains[thread_id]))
    local_only = len(set(local) - set(ids))
    # 묶음 상태: 갈라진 대화가 하나라도 있으면 묶음 전체를 갈라짐으로 보고 묶음 단위로 선택받는다.
    # 적용하면 새 대화·이어진 대화·갈라진 대화만 쓰고, 이 PC가 더 최신이거나 이 PC에만 있는 하위 대화는 그대로 둔다.
    values = set(statuses.values())
    if current is None:
        status = 'new'
    elif 'conflict' in values:
        status = 'conflict'
    elif values & {'new', 'incoming_newer'}:
        status = 'incoming_newer'
    elif 'local_newer' in values or local_only:
        status = 'local_newer'
    else:
        status = 'equal'
    counts = {key: sum(1 for x in ids[1:] if statuses[x] == key) for key, _ in CHILD_LABELS[:4]}
    counts['local_only'] = local_only
    parts = ', '.join(f'{label} {counts[key]}' for key, label in CHILD_LABELS if counts[key])
    reason = REASONS[status]
    if len(ids) > 1 or local_only:
        reason += f' · 하위 대화 {len(ids) - 1}개' + (f'({parts})' if parts and current is not None else '')
    token = digest(encoded({'archive': incoming['archiveHash'], 'home': str(home),
        'cwd': str(cwd), 'baseline': snapshot_hash(current), 'status': status}))
    return ({'status': status, 'reason': reason, 'token': token, 'source': summary(incoming), 'target': summary(current)},
        current, statuses)


def inspect_loaded(home, incoming, cwd, engine=None):
    return compare(home, incoming, cwd, engine)[0]


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
    # 이름만 주면 python.exe 폴더와 현재 폴더를 System32보다 먼저 찾으므로 전체 경로로 부른다.
    shell = os.path.join(os.environ['SystemRoot'], 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    result = subprocess.run([shell, '-NoProfile', '-NonInteractive', '-EncodedCommand',
        base64.b64encode(CLOSED_CHECK.encode('utf-16-le')).decode()],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode != 0:
        raise ValueError('Codex 앱/CLI/IDE를 모두 종료하세요. ' + result.stdout.strip() + result.stderr.strip())


def assert_closed():
    assert_no_writers()
    return engine_version()


class Busy(ValueError):
    """묶음의 대화가 지금 진행 중이라 백업하지 않았다. 실패가 아니라 턴이 끝난 뒤 다시 할 일이다."""


ACTIVE_SECONDS = 15 * 60


def turn_open(raw):
    """세션 파일의 마지막 턴이 시작만 되고 끝나지 않았으면 True."""
    for line in reversed(raw.splitlines()):
        obj = json.loads(line)
        if obj.get('type') == 'event_msg' and obj['payload'].get('type') in ('task_started', 'task_complete', 'turn_aborted'):
            return obj['payload']['type'] == 'task_started'
    return False


def assert_idle(home, family, now=None):
    """백업은 읽기만 하므로 앱이 켜져 있어도 된다. 묶음의 대화가 턴을 진행 중이면 반쯤 쓰인 기록이 담기므로 멈춘다.
    앱 강제 종료 등으로 끝나지 않은 턴은 기록이 더 없으므로, 15분 넘게 기록이 없으면 끝난 것으로 본다.
    앱이 연 채로 이어 쓰는 세션 파일은 Windows가 수정 시각을 늦게 바꾸므로 DB의 수정 시각(updated_at)도 함께 본다."""
    # ponytail: 15분 넘게 아무것도 쓰지 않는 턴(긴 명령 실행 등)은 진행 중이어도 백업된다. 턴이 끝나면 수정 시각이 바뀌어 다음 전체 백업이 다시 올린다.
    now = time.time() if now is None else now
    for item in family['members']:
        row = item['data']['thread']
        last = max(rollout_path(home, row['rollout_path']).stat().st_mtime, row['updated_at'], (row.get('updated_at_ms') or 0) / 1000)
        if turn_open(item['rollout']) and now - last < ACTIVE_SECONDS:
            raise Busy('이 대화나 하위 대화가 지금 진행 중입니다. 턴이 끝난 뒤 다시 백업하세요.')


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


def mapped(item, cwd, path, current, sessions=()):
    """가져올 대화 하나를 이 PC의 작업 폴더와 세션 파일 경로로 바꾼다. current는 이 PC의 같은 대화(없으면 None)."""
    result = copy.deepcopy(item)
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
    parsed = records(raw, row['id'], sessions)
    last_context = next((i for i in range(len(parsed)-1, -1, -1) if parsed[i]['type'] == 'turn_context'), None)
    parsed[0]['payload']['cwd'] = str(cwd)
    if 'runtime_workspace_roots' in parsed[0]['payload']:
        parsed[0]['payload']['runtime_workspace_roots'] = [str(cwd)]
    changes = {0: encoded(parsed[0]) + b'\n'}
    if last_context is not None:
        context = parsed[last_context]['payload']
        context['cwd'], context['workspace_roots'] = str(cwd), [str(cwd)]
        if current is not None:
            prior_context = next((obj['payload'] for obj in reversed(records(current['rollout'], row['id'], sessions))
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
    validate_member(result, sessions)
    return result


def replace_rows(db, item):
    row = item['data']['thread']
    thread_id = row['id']
    for table in TABLES:
        db.execute(f'DELETE FROM history.{table} WHERE thread_id=?', (thread_id,))
        for entry in item['data']['history'][table]:
            columns = list(entry)
            db.execute(f'INSERT INTO history.{table} ({",".join(columns)}) VALUES ({",".join("?" for x in columns)})', list(entry.values()))
    columns = list(row)
    db.execute(f'INSERT INTO threads ({",".join(columns)}) VALUES ({",".join("?" for x in columns)}) '
        'ON CONFLICT(id) DO UPDATE SET ' + ','.join(f'{x}=excluded.{x}' for x in columns if x != 'id'), list(row.values()))


def write_stage(path, raw):
    no_reparse(path)
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


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
    # 실제 guard는 이 PC 엔진 버전을 돌려주고, compare가 백업 엔진 버전과 정확히 비교한다.
    preview, current, statuses = compare(home, incoming, cwd, engine)
    if token != preview['token']:
        raise ValueError('미리보기 뒤 데이터가 바뀌었습니다. 다시 비교하고 선택하세요.')
    if preview['status'] in ('equal', 'local_newer'):
        return {'status': preview['status']}
    cwd = absolute(cwd)
    root = incoming['members'][0]['data']['thread']['id']
    chains = ancestors(incoming)
    local = {item['data']['thread']['id']: item for item in current['members']} if current else {}
    local_edges = {edge['child_thread_id']: edge for edge in current['edges']} if current else {}
    # 묶음의 모든 하위 대화 작업 폴더도 가져올 작업 폴더로 바꾼다(부모와 다른 폴더에서 돌던 하위 대화도 같음).
    writes = []
    for item in incoming['members']:
        row = item['data']['thread']
        if statuses[row['id']] not in WRITE:
            continue
        before = local.get(row['id'])
        if before is not None:
            path = rollout_path(home, before['data']['thread']['rollout_path'])
        else:
            date = datetime.datetime.fromtimestamp(row['created_at'], datetime.timezone.utc)
            bucket = 'archived_sessions' if row['archived'] else 'sessions'
            path = rollout_path(home, home / bucket / date.strftime('%Y/%m/%d') / f"rollout-{date:%Y-%m-%dT%H-%M-%S}-{row['id']}.jsonl")
            if path.exists():
                raise ValueError('등록되지 않은 같은 이름의 파일이 있습니다.')
        writes.append({'before': before, 'after': mapped(item, cwd, path, before, chains[row['id']]), 'path': path})
    # 새 하위 대화의 연결을 넣고, 다시 쓰는 하위 대화의 연결 상태(open·closed)를 가져온 값으로 맞춘다.
    edges = []
    for edge in incoming['edges']:
        previous = local_edges.get(edge['child_thread_id'])
        if statuses[edge['child_thread_id']] in WRITE and (previous is None or previous['status'] != edge['status']):
            edges.append({**edge, 'previous': None if previous is None else previous['status']})
    run = home / '.ctxhop-desktop-recovery' / uuid.uuid4().hex
    no_reparse(run)
    run.mkdir(parents=True)
    if current is not None:
        if engine:
            # 복구 사본으로 되살릴 때(inspect → apply) 이 PC 엔진과 비교되므로 실제 버전을 기록한다.
            current['manifest']['engineVersion'] = engine
        # 이 PC의 묶음 전체(형식 2). 복구 원본이자, 그대로 inspect → apply로 되살릴 수 있는 보관 파일이다.
        write_archive(current, run / 'before.zip')
    members = []
    for index, entry in enumerate(writes):
        after, before = entry['after'], entry['before']
        thread_id = after['data']['thread']['id']
        write_member_archive(after, engine or VERSIONS[-1], chains[thread_id], run / f'incoming-{index:04d}.zip')
        members.append({'id': thread_id, 'path': str(entry['path']),
            'before': member_hash(before) if before else 'absent', 'after': member_hash(after),
            'beforeFile': digest(before['rollout']) if before else None, 'afterFile': digest(after['rollout'])})
    journal = {'version': 2, 'status': 'pending', 'home': str(home), 'id': root, 'before': snapshot_hash(current),
        'members': members, 'edges': edges, 'createdDb': [name for name in FILES if not (home / name).exists()]}
    save_json(run / 'journal.json', journal)
    for name in journal['createdDb']:
        create_database(home / name, name)
    for index, entry in enumerate(writes):
        entry['path'].parent.mkdir(parents=True, exist_ok=True)
        write_stage(run / f'stage-{index:04d}', entry['after']['rollout'])
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
        for entry in writes:
            replace_rows(db, entry['after'])
        for edge in edges:
            db.execute('INSERT INTO thread_spawn_edges (parent_thread_id,child_thread_id,status) VALUES (?,?,?) '
                'ON CONFLICT(child_thread_id) DO UPDATE SET status=excluded.status',
                (edge['parent_thread_id'], edge['child_thread_id'], edge['status']))
        for index, entry in enumerate(writes):
            os.replace(run / f'stage-{index:04d}', entry['path'])
        if failpoint:
            failpoint('file')
        db.commit()
        if failpoint:
            failpoint('commit')
    journal['status'] = 'complete'
    save_json(run / 'journal.json', journal)
    return {'status': 'imported', 'id': root, 'recovery': str(run), 'replaced': current is not None, 'members': len(writes)}


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
    if 'version' not in journal:
        # 이전 판이 남긴 대화 하나의 기록: before.zip, incoming.zip, 임시 파일 undo.
        entries = [{key: journal[key] for key in ('id', 'path', 'before', 'after', 'beforeFile', 'afterFile')}]
        names, edges = [('incoming.zip', 'undo')], []
    elif journal['version'] == 2:
        entries, edges = journal['members'], journal['edges']
        names = [(f'incoming-{index:04d}.zip', f'undo-{index:04d}') for index in range(len(entries))]
    else:
        raise ValueError('복구 기록 형식이 다릅니다.')
    if not 1 <= len(entries) <= MAX_MEMBERS or len({entry['id'] for entry in entries}) != len(entries):
        raise ValueError('복구 기록의 대화 목록이 올바르지 않습니다.')
    before_family = read_archive(run / 'before.zip') if journal['before'] != 'absent' else None
    if before_family is not None:
        if before_family['members'][0]['data']['thread']['id'] != journal['id']:
            raise ValueError('복구 세션 ID가 다릅니다.')
        if 'version' in journal and snapshot_hash(before_family) != journal['before']:
            raise ValueError('복구 원본 검증 실패')
    local = {item['data']['thread']['id']: item for item in before_family['members']} if before_family else {}
    items = []
    for entry, (incoming_name, undo_name) in zip(entries, names):
        after = read_member_archive(run / incoming_name)
        before = local.get(entry['id'])
        if after['data']['thread']['id'] != entry['id'] or member_hash(after) != entry['after'] or \
                (member_hash(before) if before else 'absent') != entry['before']:
            raise ValueError('복구 원본 검증 실패')
        path = rollout_path(home, entry['path'])
        if path != rollout_path(home, after['data']['thread']['rollout_path']):
            raise ValueError('복구 파일 경로가 다릅니다.')
        items.append({'entry': entry, 'after': after, 'before': before, 'path': path, 'undo': run / undo_name})
    check_schema(home, allow_missing=True)
    for name in FILES:
        if not (home / name).exists():
            if name not in journal['createdDb']:
                raise ValueError('기존 DB가 없어졌습니다.')
            create_database(home / name, name)
    empty = {'thread': None, 'history': {table: [] for table in TABLES}, 'dynamicTools': []}
    added = {(edge['parent_thread_id'], edge['child_thread_id']) for edge in edges}
    def check():
        for item in items:
            thread_id, entry = item['entry']['id'], item['entry']
            baseline = item['before']['data'] if item['before'] else empty
            incoming = item['after']['data']
            data = database_data(home, thread_id)
            if data['thread'] not in (baseline['thread'], incoming['thread']):
                raise ValueError('중단 뒤 세션 메타데이터가 변경됐습니다. 자동 복구를 중단합니다.')
            if data['dynamicTools'] != baseline['dynamicTools']:
                raise ValueError('중단 뒤 도구 설정이 변경됐습니다.')
            for table in TABLES:
                if data['history'][table] not in (baseline['history'][table], incoming['history'][table]):
                    raise ValueError('중단 뒤 세션 이력이 변경됐습니다. 자동 복구를 중단합니다.')
            file_hash = digest(item['path'].read_bytes()) if item['path'].exists() else None
            if file_hash not in (entry['beforeFile'], entry['afterFile']):
                raise ValueError('중단 뒤 세션 파일이 변경됐습니다. 자동 복구를 중단합니다.')
            if item['before'] is None:
                with ro(home / FILES[0]) as db:
                    linked = {(row[0], row[1]) for row in db.execute('SELECT parent_thread_id,child_thread_id '
                        'FROM thread_spawn_edges WHERE parent_thread_id=? OR child_thread_id=?', (thread_id, thread_id))}
                    if db.execute('SELECT 1 FROM thread_attachments WHERE thread_id=?', (thread_id,)).fetchone() or linked - added:
                        raise ValueError('새 세션에 다른 작업이 연결됐습니다. 자동 삭제를 중단합니다.')
        with ro(home / FILES[0]) as db:
            for edge in edges:
                row = db.execute('SELECT parent_thread_id,status FROM thread_spawn_edges WHERE child_thread_id=?',
                    (edge['child_thread_id'],)).fetchone()
                state = None if row is None else tuple(row)
                if state not in ((edge['parent_thread_id'], edge['status']),
                        None if edge['previous'] is None else (edge['parent_thread_id'], edge['previous'])):
                    raise ValueError('중단 뒤 하위 대화 연결이 변경됐습니다. 자동 복구를 중단합니다.')
    check()
    for item in items:
        if item['before']:
            no_reparse(item['undo'])
            if item['undo'].exists():
                if digest(item['undo'].read_bytes()) != item['entry']['beforeFile']:
                    raise ValueError('복구 임시 파일이 변경됐습니다.')
            else:
                write_stage(item['undo'], item['before']['rollout'])
    with sqlite3.connect(home / FILES[0], timeout=10) as db:
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('ATTACH DATABASE ? AS history', (str(home / FILES[1]),))
        db.execute('BEGIN IMMEDIATE')
        guard()
        check_schema(home)  # 엔진 버전을 보지 않으므로 쓰기 잠금 안에서 구조를 다시 확인한다.
        check()
        for edge in edges:
            if edge['previous'] is None:
                db.execute('DELETE FROM thread_spawn_edges WHERE parent_thread_id=? AND child_thread_id=?',
                    (edge['parent_thread_id'], edge['child_thread_id']))
            else:
                db.execute('UPDATE thread_spawn_edges SET status=? WHERE child_thread_id=?', (edge['previous'], edge['child_thread_id']))
        for item in items:
            if item['before']:
                replace_rows(db, item['before'])
                os.replace(item['undo'], item['path'])
            else:
                for table in TABLES:
                    db.execute(f'DELETE FROM history.{table} WHERE thread_id=?', (item['entry']['id'],))
                db.execute('DELETE FROM threads WHERE id=?', (item['entry']['id'],))
        db.commit()
    for item in items:
        if item['before'] is None and item['path'].exists():
            item['path'].unlink()  # 확인한 새 세션 파일만 삭제. 복구 기록과 DB는 보존.
    journal['status'] = 'rolled_back'
    save_json(run / 'journal.json', journal)
    return {'status': 'rolled_back', 'id': journal['id'], 'recovery': str(run), 'members': len(items)}


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
            # 앱 종료 대신 이 묶음이 진행 중인지(assert_idle)와 내보내는 동안 바뀌지 않았는지를 본다.
            engine = engine_version()
            if pending(home):
                raise ValueError('중단된 가져오기를 먼저 복구하세요.')
            thread_id = native_id(args.id)
            unreadable = (ValueError, OSError, sqlite3.Error)
            try:
                snapshot = selected(home, thread_id)
            except unreadable:
                time.sleep(1)  # 앱이 세션 파일과 이력 DB를 쓰는 사이에 읽었을 수 있으므로 한 번 더 읽는다. 또 실패하면 실패로 보고한다.
                snapshot = selected(home, thread_id)
            if snapshot is None:
                raise ValueError('선택한 세션이 없습니다.')
            assert_idle(home, snapshot)
            snapshot['manifest']['engineVersion'] = engine
            write_archive(snapshot, args.output)
            try:
                changed = snapshot_hash(selected(home, thread_id)) != snapshot_hash(snapshot)
            except unreadable:
                changed = True  # 방금 읽은 묶음을 못 읽으면 앱이 쓰는 중이거나 옮겼다
            if changed:
                raise Busy('내보내는 동안 선택한 세션이 변경됐습니다. 생성 파일을 사용하지 마세요.')
            info = summary(snapshot)
            result = {'status': 'exported', 'metadata': {key: info[key] for key in
                ('sessionId', 'title', 'sourceCwd', 'updatedAt', 'historyMode', 'cliVersion', 'recordCount')},
                'session': info, 'folders': work_folders(snapshot),
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
        result = {'status': 'busy' if isinstance(exc, Busy) else 'blocked', 'reason': str(exc), 'token': None}
        if args.action == 'apply':
            # 중단된 가져오기의 복구 기록 위치를 GUI 오류와 함께 보여 준다.
            with contextlib.suppress(Exception):
                result['pending'] = [str(p.parent) for p in pending(check_home(args.home))]
        print(json.dumps(result, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
