"""메타데이터 DB만 읽는 대용량 목록 진단."""
import argparse
import json
import time
from pathlib import Path
import desktop_sessions as d

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--home', required=True)
    args = p.parse_args()
    home = d.check_home(args.home)
    d.check_schema(home)
    start = time.perf_counter()
    page = d.list_sessions(home, limit=200)
    elapsed = (time.perf_counter() - start) * 1000
    with d.ro(home / d.FILES[0]) as db:
        versions = [list(row) for row in db.execute('SELECT history_mode,cli_version,COUNT(*) FROM threads GROUP BY history_mode,cli_version')]
        matches = d.schema_of(db) == d.trusted_schema()[d.FILES[0]]
    print(json.dumps({'total': page['total'], 'returned': len(page['sessions']), 'elapsedMs': round(elapsed, 2),
        'stateSchemaMatches': matches, 'historicalVersions': versions}, ensure_ascii=False))
