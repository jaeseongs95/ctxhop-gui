"""시험 전용 진입점. 앱 종료 검사와 엔진 버전 조회만 CTXHOP_TEST_ENGINE 값으로 바꾸고 실제 CLI(main)를 실행한다.
Worker와 GUI는 이 파일을 호출하지 않는다. Worker는 SHA를 고정한 desktop_sessions.py만 실행한다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import desktop_sessions as d

d.assert_closed = d.engine_version = lambda: os.environ['CTXHOP_TEST_ENGINE']
d.assert_no_writers = lambda: None

if __name__ == '__main__':
    raise SystemExit(d.main())
