"""격리된 CODEX_HOME만 사용하는 설치본 app-server 시험. 모델 요청 없음."""
import argparse
import json
import os
import queue
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Rpc:
    def __init__(self, exe, home):
        self.home = Path(home).resolve()
        env = os.environ.copy()
        env['CODEX_HOME'] = str(self.home)
        for key in ('OPENAI_API_KEY', 'CODEX_API_KEY'):
            env.pop(key, None)
        self.proc = subprocess.Popen([str(exe), 'app-server'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8',
            env=env, cwd=self.home, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.messages = queue.Queue()
        self.errors = []
        def read():
            for line in self.proc.stdout:
                try:
                    self.messages.put(json.loads(line))
                except ValueError:
                    self.errors.append('invalid stdout')
        def stderr():
            for line in self.proc.stderr:
                self.errors.append(line.rstrip())
        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=stderr, daemon=True).start()
        self.serial = 0
        try:
            self.call('initialize', {'clientInfo': {'name': 'ctxhop-isolated-test',
                'version': '0.1'}, 'capabilities': {'experimentalApi': True}})
            self.notify('initialized', {})
        except Exception:
            self.close()
            raise

    def notify(self, method, params):
        self.proc.stdin.write(json.dumps({'method': method, 'params': params}) + '\n')
        self.proc.stdin.flush()

    def call(self, method, params):
        self.serial += 1
        req_id = self.serial
        self.proc.stdin.write(json.dumps({'id': req_id, 'method': method, 'params': params}) + '\n')
        self.proc.stdin.flush()
        while True:
            msg = self.messages.get(timeout=30)
            if msg.get('id') == req_id:
                if 'error' in msg:
                    raise RuntimeError(json.dumps(msg['error'], ensure_ascii=False))
                return msg['result']
            if 'id' in msg and 'method' in msg:
                raise RuntimeError('unexpected server request: ' + msg['method'])

    def close(self):
        if self.proc.stdin.closed:
            return
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.terminate()  # 이 객체가 생성한 격리 서버 PID만 종료
            self.proc.wait(timeout=10)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', required=True)
    p.add_argument('--root', required=True)
    p.add_argument('--sandbox', default='read-only', choices=('read-only', 'danger-full-access'))
    p.add_argument('--approval', default='untrusted', choices=('untrusted', 'never'))
    p.add_argument('--turns', type=int, choices=(1, 2), default=2)
    args = p.parse_args()
    root = Path(args.root).resolve()
    home = root / ('probe-' + uuid.uuid4().hex)
    home.mkdir(parents=True)
    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            response = {'id': 'resp_fixture', 'object': 'response', 'status': 'completed',
                'output': [{'id': 'msg_fixture', 'type': 'message', 'role': 'assistant',
                    'status': 'completed', 'content': [{'type': 'output_text',
                        'text': 'CTXHOP_NATIVE_FIXTURE_REPLY', 'annotations': []}]}],
                'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            events = [
                {'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': []}},
                {'type': 'response.output_item.added', 'output_index': 0, 'item': response['output'][0]},
                {'type': 'response.output_text.delta', 'item_id': 'msg_fixture', 'output_index': 0,
                    'content_index': 0, 'delta': 'CTXHOP_NATIVE_FIXTURE_REPLY'},
                {'type': 'response.output_item.done', 'output_index': 0, 'item': response['output'][0]},
                {'type': 'response.completed', 'response': response}]
            for event in events:
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
            self.wfile.flush()
    server = HTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/v1'
    policy = '' if args.sandbox == 'read-only' else 'approval_policy = "never"\ndefault_permissions = ":danger-full-access"\n'
    (home / 'config.toml').write_text(policy + 'model_provider = "fixture"\nmodel = "fixture-model"\n'
        '[model_providers.fixture]\nname = "fixture"\nwire_api = "responses"\n'
        f'base_url = "{url}"\nrequires_openai_auth = false\nsupports_websockets = false\n', encoding='utf-8')
    rpc = None
    report = {'home': str(home), 'exe': args.exe}
    try:
        rpc = Rpc(args.exe, home)
        result = rpc.call('thread/start', {'cwd': str(home), 'historyMode': 'paginated',
            'sandbox': args.sandbox, 'approvalPolicy': args.approval})
        thread_id = result['thread']['id']
        report['threadId'] = thread_id
        report['start'] = result
        turn = rpc.call('turn/start', {'threadId': thread_id, 'input': [
            {'type': 'text', 'text': 'CTXHOP_NATIVE_FIXTURE_USER'}]})
        report['turnStart'] = turn
        while True:
            event = rpc.messages.get(timeout=30)
            if event.get('method') == 'turn/completed':
                report['turnCompleted'] = event['params']
                break
        report['read'] = rpc.call('thread/read', {'threadId': thread_id, 'includeTurns': False})
        report['turns'] = rpc.call('thread/turns/list', {'threadId': thread_id, 'limit': 20})
        report['resume'] = rpc.call('thread/resume', {'threadId': thread_id,
            'excludeTurns': True, 'sandbox': 'read-only', 'approvalPolicy': 'untrusted'})
        rpc.close()
        # 앱이 처음 열 때처럼 요청 값 없이 다시 열면 엔진이 이 PC 설정을 thread_settings_applied로 남긴다.
        rpc = Rpc(args.exe, home)
        rpc.call('thread/resume', {'threadId': thread_id, 'excludeTurns': True})
        rpc.close()
        import desktop_sessions as d
        d.write_archive(d.selected(home, thread_id), home / 'first.zip')
        if args.turns == 2:
            rpc = Rpc(args.exe, home)
            rpc.call('thread/resume', {'threadId': thread_id, 'excludeTurns': True,
                'sandbox': args.sandbox, 'approvalPolicy': args.approval})
            rpc.call('turn/start', {'threadId': thread_id, 'input': [
                {'type': 'text', 'text': 'CTXHOP_NATIVE_FIXTURE_USER_SECOND'}]})
            while True:
                event = rpc.messages.get(timeout=30)
                if event.get('method') == 'turn/completed':
                    break
            report['secondTurns'] = rpc.call('thread/turns/list', {'threadId': thread_id, 'limit': 20, 'itemsView': 'full'})
        report['ok'] = True
    except Exception as exc:
        report['ok'] = False
        report['error'] = str(exc)
    finally:
        if rpc:
            rpc.close()
        server.shutdown()
        server.server_close()
    (home / 'probe.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'home': str(home), 'ok': report['ok'], 'error': report.get('error')}, ensure_ascii=False))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
