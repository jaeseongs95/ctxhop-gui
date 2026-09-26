"""시험 엔진이 만든 DB에서 구조와 migration만 읽는다. 사용자 대화는 복사하지 않는다."""
import argparse
import base64
import hashlib
import json
import sqlite3
from pathlib import Path


def capture(home):
    result = {}
    for name in ('state_5.sqlite', 'thread_history_1.sqlite'):
        path = Path(home) / name
        with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True) as db:
            objects = db.execute("SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL "
                "AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
            migrations = db.execute('SELECT version,description,success,checksum FROM _sqlx_migrations ORDER BY version').fetchall()
            result[name] = {'objects': objects, 'migrations': [[v,d,s,base64.b64encode(c).decode()] for v,d,s,c in migrations]}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture-home', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    data = json.dumps(capture(args.fixture_home), ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    with open(args.output, 'xb') as output:
        output.write(data)
    print(hashlib.sha256(data).hexdigest())
