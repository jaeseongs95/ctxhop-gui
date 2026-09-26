# CtxHop vNext 검토 후보

한국어 | [English](README.en.md)

Claude Code와 Codex Desktop 대화를 한 창에서 백업·복원하는 별도 후보입니다. 기존 `ctxhop-gui` 묶음과 사용자 저장소를 교체하지 않습니다. `Run-CtxHop-GUI-vNext.cmd`로 실행하며 Windows PowerShell 5.1과 WinForms를 사용합니다.

Codex 경로는 `backend\desktop_sessions.py`와 암호화 bundle 실행 파일 `bin\ctxhop.exe`의 SHA256을 `Worker.ps1`에 고정해 두었습니다. 파일이 없거나 바뀌면 중단합니다.

- **Python**: Codex Desktop이 설치한 런타임 `%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`를 씁니다. 다른 Python 3.10 이상을 쓰려면 그 PC의 `backend\runtime.json`에 `{"pythonPath":"절대경로"}`를 둡니다. PATH의 Python이나 자동 설치는 쓰지 않습니다.
- **지원 엔진**: Codex Desktop `0.158.0-alpha.2`, `0.158.0-alpha.2.1`. 가져올 때는 **백업한 PC와 이 PC의 엔진 버전이 정확히 같아야** 하며, 다르면 쓰기 전에 차단합니다. DB 구조가 고정값과 달라도 차단합니다. 앱이 새 버전으로 업데이트되면 `backend\test_suite.py`로 다시 검증한 뒤 `VERSIONS`에 추가해야 합니다.
- 제목의 줄바꿈은 공유 백업 목록에서 공백으로 바뀝니다. 대화 내용은 바뀌지 않습니다.
- 하위 에이전트 대화는 목록에 보이지만 **작업 불가**로 표시됩니다. 부모 대화를 선택하세요. 동적 도구가 등록된 대화 등 그 밖의 지원하지 않는 대화는 백업을 누르면 쓰기 전에 이유와 함께 중단됩니다.
- 두 PC 사이의 실제 대화 왕복은 아직 실행하지 않았습니다. 처음에는 짧은 시험 대화로 확인하세요.
- **언어**: 설정 탭의 **Language / 언어**에서 한국어나 English를 고릅니다. 프로그램을 다시 시작하면 화면과 작업 메시지가 그 언어로 나옵니다. Python 백엔드가 돌려주는 차단 사유와 ctxhop·Codex·Claude 실행 파일이 출력하는 글은 원래 언어 그대로입니다.

## 사용 순서

1. **연결 설정 · 초대**에서 기존 ctxhop 연결을 확인합니다. 새 PC는 원본 PC가 만든 초대 JSON으로 연결합니다. 암호가 필요하면 작업 입력 창에 직접 입력하고 설정 동기화 질문에는 **n**을 입력합니다.
2. **Claude Code**는 프로젝트 폴더와 공통 이름을 등록한 뒤 기존 방식으로 한 대화를 선택합니다. 원본 ID·프로젝트·환경 적용 차단·실행 파일 해시·복구 기록 검사가 유지됩니다.
3. **Codex Desktop**은 설정 탭의 Codex 데이터 폴더를 확인합니다. 목록에는 전체 프로젝트와 보관된 대화, 공유 백업이 포함됩니다. 제목·UUID·원본 폴더 검색과 200개 화면 페이지를 사용합니다. 목록을 다시 불러오면 해당 검색을 백엔드 목록 조회에도 전달합니다. 목록은 대화 본문을 스캔하지 않고 메타데이터를 페이지별로 읽습니다.
4. **Codex 백업**: 앱을 직접 종료하고 로컬 대화 한 개를 선택하여 백업합니다. 공유 백업은 암호화된 별도 snapshot으로 보관됩니다. 같은 UUID의 여러 백업도 서로 다른 행으로 표시하며 변경 날짜로 자동 선택하거나 덮어쓰지 않습니다.
5. **Codex 복원**: 실제 대상 작업 폴더를 선택하고 Drive 다운로드 완료를 확인합니다. 공유 백업 한 개 또는 여러 개를 선택한 뒤 **미리보기 후 복원**을 누릅니다. 검사 동안에는 로컬 대화 파일과 DB를 변경하지 않습니다. 다만 검사 때 엔진 버전을 확인하느라 Codex가 `%CODEX_HOME%`(없으면 `%USERPROFILE%\.codex`)의 `tmp\arg0`에 임시 파일을 만들 수 있습니다(Codex가 다음 실행 때 정리함).
6. 항목별 확인 창은 이 PC에 없는 대화, 같은 기록, 공유 기록의 연장, 로컬 기록의 연장, 갈라진 기록, 복원 불가 항목을 함께 보여 줍니다. 모든 행의 기본 선택은 **건너뛰기**입니다. **로컬 유지** 역시 쓰지 않습니다. 복원하려는 행에서 **공유 백업 복원**을 직접 고릅니다. 같은 UUID에서는 복원할 백업을 한 개만 고를 수 있습니다. 손상되거나 형식이 맞지 않는 항목에는 복원 선택이 없습니다.
7. 선택 내용과 작업 폴더를 확인하고 마지막 승인 창에서 복원을 승인합니다. Codex 앱이 실행 중이면 백엔드가 중단하고 직접 종료 안내를 표시합니다. 앱이나 작업 프로세스를 강제 종료하지 않습니다. 검사 토큰·백업 파일·ID·데이터 폴더·대상 폴더가 달라지면 다시 검사해야 합니다.
8. 복원 뒤 Codex Desktop을 직접 열고 UUID, 대화 내용, 작업 폴더를 확인합니다. 자동 프롬프트나 CLI 재개 명령을 보내지 않습니다. 프로젝트 파일·Git 상태·도구 설치는 별도로 준비합니다.

복원이 실패하면 다음 항목을 자동 적용하지 않고 백엔드가 반환한 원본 복구 기록(`pending` 폴더 목록)을 표시합니다. 원본 백업과 pending 복구 기록을 보존합니다. 중단된 기록이 남아 있으면 이후 백업·복원이 차단되므로, **Codex 앱을 종료한 상태에서** 이 폴더에서 확인·복구합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action pending -HomePath 'GUI 설정 탭의 Codex 데이터 폴더'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action recover -HomePath 'GUI 설정 탭의 Codex 데이터 폴더' -Run 'pending에 나온 정확한 폴더'
```

- `-HomePath`는 GUI 설정 탭의 Codex 데이터 폴더와 **같은 문자열**이어야 합니다(기본값 `%USERPROFILE%\.codex`). 이 명령도 GUI와 같은 Python(기본 경로 또는 `backend\runtime.json`)과 고정 백엔드 해시를 씁니다. 경로 끝에 `\`를 붙이지 마세요. `powershell.exe -File`로 실행하면 끝의 `\'`가 따옴표로 해석돼 경로가 깨집니다(이때는 쓰기 전에 폴더가 없다며 멈춤).
- `recover`는 가져오기 전 상태로 되돌립니다. 중단 뒤 앱이 그 대화를 다시 썼거나 DB가 일부만 만들어졌으면 스스로 멈춥니다.
- `recover`는 앱 종료와 DB 구조만 확인하고 엔진 버전은 보지 않습니다. 실패 뒤 Codex가 업데이트돼도 DB 구조가 같으면 복구할 수 있고, 구조가 바뀌었으면 쓰기 전에 멈춥니다. 이때는 바로 아래의 pending 폴더 옮기기 절차를 따릅니다(`before.zip` 되살리기는 엔진 버전이 같아야 해서 이 경우 쓸 수 없음).
- **복구가 멈췄거나, 가져오기는 끝났는데 완료 기록만 남은 경우**: 자동 복구를 반복하지 말고 Codex 앱에서 해당 UUID 대화를 확인합니다. 현재 상태를 유지하려면 `pending`에 나온 폴더를 `.ctxhop-desktop-recovery` 밖의 보관 위치로 **옮깁니다**(지우지 않음). 폴더 안 `before.zip`은 가져오기 전 원본, `incoming.zip`은 가져온 내용입니다. 옮기면 차단이 풀립니다.
- **공유 백업으로 덮어쓴 뒤 원래 로컬 기록으로 되돌리기**: 갈라진 기록에서 공유 백업을 복원해도 이 PC의 이전 기록은 `<Codex 데이터 폴더>\.ctxhop-desktop-recovery\<작업ID>\before.zip`에 남습니다(해당 UUID·시각의 폴더를 찾습니다). 되살리려면 앱을 종료한 상태에서 이 파일을 복원 대상으로 검사한 뒤, 출력된 `token`으로 적용합니다. 이 적용도 새 복구 폴더에 직전 기록을 남깁니다. 복구 사본에는 복원할 때의 이 PC 엔진 버전이 기록되므로, 그 뒤 엔진이 바뀌었으면 엔진이 다르다는 이유로 쓰기 전에 차단됩니다(데이터는 그대로 보존).

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action inspect -HomePath 'Codex 데이터 폴더' -Archive '...\before.zip' -Cwd '그 대화의 작업 폴더'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action apply -HomePath 'Codex 데이터 폴더' -Archive '...\before.zip' -Cwd '그 대화의 작업 폴더' -Token '위 출력의 token' -Choice incoming
```
- 전체 세션 폴더나 DB를 통째로 덮어쓰지 않습니다. 기존 Claude 복구 동작은 복사한 작업기에 그대로 유지됩니다.

## 로컬 파일과 후보 경계

- 선택값: `%LOCALAPPDATA%\CtxHopGUI\vnext-preferences.json`
- 임시 작업 요청·결과: `%LOCALAPPDATA%\CtxHopGUI\jobs`
- Codex 백업·검사 파일: `%LOCALAPPDATA%\CtxHopGUI\staging\고유ID`. 각 작업은 새 폴더·새 파일을 만들며 현재 사용자에게만 접근을 허용합니다. 백업 업로드나 복원이 성공하면 그 작업의 평문 사본을 지웁니다. 실패한 작업과 건너뛰거나 취소한 미리보기 폴더는 복원 토큰과 실패 증거를 위해 남으므로, 필요 없으면 직접 지웁니다. 이 폴더의 평문 대화는 Drive로 올리지 마세요.
- Claude: `ClaudeWorker.ps1`은 기존 안정 Worker(SHA256 `D08E9A15…`)에서 화면·오류 문장을 `Strings.ps1`로 옮기고 요청의 언어를 적용하는 두 줄만 더한 사본입니다. `bin/ctxhop-claude.exe`는 기존 `0.2.0-gui.1` 해시를 요구합니다.
- 문장: 화면과 작업 메시지의 한국어·영어 문장은 `Strings.ps1`에 `키=@('한국어','English')`로 모여 있습니다.
- Codex: `Worker.ps1`이 frozen Python 백엔드와 `bin/ctxhop.exe`의 bundle 명령을 연결합니다. UI는 본문·DB·압축 파일 형식을 직접 해석하지 않습니다.

원본 Claude 수정 소스 전체를 중복하지 않습니다. 프로덕션 저장소, 실제 사용자 세션, 인증 설정과 전역 실행 정책은 이 후보 작성·테스트에서 변경하지 않습니다.

## 격리 검사

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-ClaudeWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-ClaudeGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-DesktopGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-Strings.ps1
& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" -X utf8 .\backend\test_suite.py --exe '설치된 Desktop codex.exe 절대경로'
```

앞의 네 개는 새 임시 폴더와 합성 메타데이터를 쓰며 백엔드·transport·Codex·Claude 실행을 mock으로 대체합니다. `Test-DesktopIntegration.ps1`은 설치된 Codex Desktop 엔진으로 임시 폴더에 시험 대화를 만든 뒤 **고정한 실제 백엔드**를 Worker로 호출합니다(전송만 mock). `Test-Strings.ps1`은 두 언어 문장의 짝과 자리표시자, 코드에 남은 번역 안 된 한글, 영어 화면과 영어 오류 메시지를 확인합니다. `backend\test_suite.py`는 격리 `CODEX_HOME`과 localhost 고정 응답으로 실제 엔진의 paginated 대화를 만들고 이식·읽기·재개를 확인합니다. 결과와 해시는 `verification.md`에 있습니다.
