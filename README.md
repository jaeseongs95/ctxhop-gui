# CtxHop GUI vNext (Windows)

한국어 | [English](README.en.md)

Claude Code와 Codex Desktop 대화를 한 창에서 백업하고 다른 PC에서 복원합니다. Windows에 기본으로 들어 있는 Windows PowerShell 5.1로 실행합니다. 기존 `ctxhop-gui` 묶음과 사용자 저장소를 교체하지 않습니다.

> **미리보기 판입니다.** 격리 시험은 모두 통과했지만, 두 PC 사이의 실제 대화 왕복은 아직 해 보지 않았습니다. 처음에는 짧은 시험 대화로 확인하세요.

## 준비물

- Windows PowerShell 5.1이 있는 Windows
- 두 PC가 함께 보는 폴더(예: Google Drive 폴더). 암호화한 백업을 여기에 둡니다. 이 폴더에 쓸 수 있는 사람은 백업을 바꿔 넣거나 이후 백업을 자기가 읽을 수 있게 만들 수 있으므로, 다른 사람과 공유하지 않는 본인 폴더를 씁니다(`verification.md`의 보안 전수조사 참고).
- **Codex Desktop**을 쓸 때:
  - Codex Desktop 엔진 `0.158.0-alpha.2` 또는 `0.158.0-alpha.2.1`. 백업한 PC와 복원할 PC의 엔진 버전이 **정확히 같아야** 하며, 다르면 쓰기 전에 차단합니다.
  - Codex Desktop이 설치한 Python(`%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`). 다른 Python 3.10 이상을 쓰려면 그 PC의 `backend\runtime.json`에 `{"pythonPath":"절대경로"}`를 둡니다. PATH의 Python이나 자동 설치는 쓰지 않습니다.

## 설치

[Releases](https://github.com/jaeseongs95/ctxhop/releases)에서 설치 파일이나 zip 중 하나를 받습니다. 두 파일에 든 GUI는 같습니다. 받은 파일이 릴리스 페이지의 SHA256과 같은지 먼저 확인합니다.

**설치 파일(추천)**

1. `CtxHop-GUI-vNext-<날짜>-setup.exe`를 실행합니다. 서명 없는 설치 파일이라 **Windows의 PC 보호** 창이 뜰 수 있습니다. 그러면 **추가 정보** → **실행**을 누릅니다.
2. 관리자 권한 없이 `%LOCALAPPDATA%\Programs\CtxHop GUI vNext`에 설치되고, 시작 메뉴와 바탕화면(설치 중 선택)에 **CtxHop GUI vNext** 바로가기가 생깁니다. 설치된 파일은 차단을 해제할 필요가 없습니다.
3. 마지막 화면에서 바로 실행하거나, 나중에 바로가기로 실행합니다.

- 새 판은 같은 설치 파일 방식으로 덮어 설치합니다.
- GUI 작업(목록·백업·복원·설정)이 진행 중이면 설치와 제거가 그 작업이 끝날 때까지 기다리라고 안내합니다. 작업이 끝난 뒤 계속합니다.
- 지울 때는 Windows **설정** → **앱** → **설치된 앱**에서 **CtxHop GUI vNext**를 제거합니다. `%LOCALAPPDATA%\CtxHopGUI`의 GUI 설정·작업 폴더와 ctxhop 설정은 지우지 않습니다. 직접 만든 `backend\runtime.json`은 설치 폴더에 남습니다.
- 설치 파일을 만드는 스크립트는 [`installer/CtxHop-GUI-vNext.iss`](installer/CtxHop-GUI-vNext.iss)(Inno Setup 6.7)입니다.

**zip**

1. **압축을 풀기 전에 차단을 해제합니다.** zip을 오른쪽 클릭 → **속성** → **차단 해제**를 체크하거나 `Unblock-File .\CtxHop-GUI-vNext-<날짜>.zip`을 실행합니다. 이 단계를 건너뛰면 Windows가 풀린 `.ps1`을 막아 GUI가 아무 표시 없이 뜨지 않습니다. 이미 풀었다면 그 폴더를 지우고 차단을 해제한 zip으로 다시 풉니다.
2. 압축을 풀고 `ctxhop-gui-vnext\Run-CtxHop-GUI-vNext.cmd`를 실행합니다.

설치 파일과 zip에는 저장소에 없는 `bin\ctxhop.exe`와 `bin\ctxhop-claude.exe`가 들어 있습니다. [무결성 검사](#무결성-검사)를 참고하세요.

**두 PC 모두 이 판으로 올리세요.** 이 판은 하위 에이전트 대화를 부모 대화와 함께 옮깁니다. 이 판이 만든 Codex 공유 백업은 이전 판이 읽지 못해 쓰기 전에 멈추고, Claude 대화 옆 폴더는 이 판끼리만 옮겨집니다.

## 처음 설정

**연결 설정 · 초대** 탭에서 합니다.

1. **Language / 언어**에서 한국어나 English를 고르고 프로그램을 다시 시작합니다. 화면과 작업 메시지가 그 언어로 바뀝니다. Python 백엔드가 돌려주는 차단 사유와 ctxhop·Codex·Claude 실행 파일이 출력하는 글은 원래 언어 그대로입니다.
2. 이 PC에서 이미 ctxhop을 쓰고 있으면 **현재 연결 확인**만 누르고 나머지는 건너뜁니다. 기존 설정은 그대로 쓰며, **초기 설정 / 초대로 연결**은 기존 설정 위에서 실행되지 않습니다.
3. **처음 PC**: 공유 폴더 안에 빈 폴더를 만들어 **Drive 저장소 경로**로 지정합니다. **초대 JSON (다른 PC)** 칸은 비워 두고, **이 PC 이름**을 적은 뒤 **초기 설정 / 초대로 연결**을 누르면 작업 창이 열리고, 암호는 그 창에 직접 입력합니다.
   - 설정 동기화 질문(`[Y/n]`)은 Enter만 누르면 Y가 됩니다. **반드시 `n`을 입력하세요.** Y면 이 GUI로 백업할 수 없습니다.
   - 두 번 입력한 암호가 다르거나 복구 키 확인을 잘못 입력하면 아무것도 저장되지 않습니다. 같은 버튼을 다시 누르면 됩니다.
   - 이 단계에서 받은 복구 키는 안전한 곳에 오프라인으로 보관합니다.
4. **다른 PC**: 처음 PC에서 **다른 PC용 초대 만들기**로 초대 JSON을 만들어 다른 PC로 옮깁니다. 다른 PC에서는 **초대 JSON (다른 PC)**에서 그 파일을 고르고 **이 PC 이름**을 적은 뒤 **초기 설정 / 초대로 연결**을 누릅니다.
5. 설정이 끝난 PC는 기기 인증을 쓰므로 목록·백업·복원 때 암호를 묻지 않습니다.

## Claude Code 대화 백업·복원

**대화 백업 · 복원** 탭에서 에이전트를 **Claude Code**로 고릅니다.

1. 프로젝트 폴더를 고르고 **공통 이름**을 적은 뒤 **프로젝트 등록**을 누릅니다. 같은 프로젝트는 모든 PC에서 같은 공통 이름을 씁니다. 등록한 폴더는 **등록된 프로젝트**에 나옵니다.
   - 상위 폴더와 그 하위 폴더를 **서로 다른 공통 이름**으로 등록하지 마세요. ctxhop이 그 안의 목록 불러오기와 등록을 모두 거부하므로, GUI가 이런 등록을 막습니다.
   - 이미 겹쳐 있으면 **등록된 프로젝트**에서 한쪽을 골라 **등록 해제**를 누릅니다. 대화 파일과 백업은 지우지 않습니다. 폴더를 이미 지웠으면 그 공통 이름의 등록이 그 경로 하나뿐일 때만 해제됩니다.
2. **대화 목록 불러오기**를 누르고 대화 하나를 고릅니다.
3. **선택한 대화 백업**을 누르거나, 공유 백업을 이 PC로 가져오려면 **미리보기 후 복원**을 누릅니다. 원본 ID·프로젝트·실행 파일 해시를 확인하고, 환경 적용을 막고, 복원하는 동안 복구 기록을 남깁니다.
4. **선택한 대화 열기**는 그 대화를 Claude Code에서 엽니다.

백업·복원 전에 Claude Code와 VS Code·Cursor·Windsurf처럼 Claude를 띄울 수 있는 편집기를 모두 닫습니다. 실행 중이면 오류에 닫아야 할 프로그램 이름과 PID가 나옵니다.

Claude Code는 대화 파일(`<세션ID>.jsonl`) 옆에 같은 이름의 폴더를 두고 하위 에이전트 기록(`subagents\`)과 저장한 도구 결과(`tool-results\`)를 넣습니다. 백업과 복원은 이 폴더를 대화와 함께 옮깁니다.

- 복원은 이 PC에만 있는 파일을 지우지 않습니다. 내용이 바뀌는 파일의 원본은 복구 기록 옆 `.companion` 폴더에 남깁니다.
- 파일은 그대로 복사합니다. 파일 안에 적힌 경로를 이 PC의 폴더로 바꾸지 않습니다.
- 이전 판으로 만든 백업에는 이 폴더가 없어 대화 파일만 복원되며, 완료 메시지가 그렇다고 알려 줍니다. 원본 PC에서 이 판으로 다시 백업하면 함께 옮겨집니다.
- 이 폴더는 이 GUI로 백업할 때만 올라갑니다. 그 뒤 다른 ctxhop(예: Claude Code hook의 자동 push)이 대화만 올렸다면, 복원되는 폴더는 마지막 GUI 백업 때의 내용입니다.

## Codex Desktop 대화 백업·복원

에이전트를 **Codex Desktop**으로 고르고, 설정 탭의 **Codex 데이터 폴더**를 확인합니다(기본값 `%USERPROFILE%\.codex`).

### 목록

목록은 전체 프로젝트와 보관된 대화, 공유 백업을 불러옵니다. 제목·UUID·원본 폴더로 검색하고, 한 화면에 200개씩 봅니다. 목록을 다시 불러오면 검색어를 백엔드 조회에도 넘깁니다. 목록은 대화 본문을 읽지 않고 메타데이터만 페이지별로 읽습니다.

- **이 프로젝트 대화만**(기본으로 켜짐)은 **프로젝트** 칸의 폴더로 목록을 거릅니다.
  - 이 PC의 대화는 그 폴더나 그 아래 폴더에서 만든 것만 보입니다.
  - 공유 백업은 원본 폴더가 같거나 그 아래이거나, 마지막 폴더 이름이 같으면 보입니다. 다른 PC에서 경로가 달라도 같은 이름의 프로젝트 폴더면 보이도록 한 것입니다. 이름만 같은 다른 프로젝트도 섞일 수 있으니 복원 전 미리보기에서 원본 폴더를 확인하세요.
  - 경로 앞의 `\\?\`, 대소문자, 끝의 `\`는 무시합니다. 끄면 모든 프로젝트를 봅니다.
- 제목의 줄바꿈은 공유 백업 목록에서 공백으로 바뀝니다. 대화 내용은 바뀌지 않습니다.
- 하위 에이전트 대화는 목록에 따로 나오지 않고 부모 대화와 한 묶음으로 다닙니다. 부모 행의 맥락 칸에 `· 하위 N`으로 하위 대화 수가 나옵니다. 부모 대화가 없는 하위 에이전트 대화는 보이지 않고 백업하지 않습니다.
- 이전 판으로 만든 공유 백업은 `· 이전 형식`으로 표시됩니다. 부모 대화만 들어 있어 복원하면 부모 대화만 가져옵니다.
- 동적 도구가 등록된 대화처럼 지원하지 않는 대화는 쓰기 전에 이유와 함께 멈춥니다. 묶음 안의 대화 하나라도 그러면 묶음 전체가 멈춥니다.

### 백업

1. 로컬 대화 하나를 고르고 **선택한 대화 백업**을 누릅니다. Codex 앱은 켜 둬도 됩니다.

백업은 읽기만 하므로 Codex 앱을 종료하지 않아도 됩니다. 다만 그 대화나 하위 대화가 지금 진행 중이면(마지막 턴이 끝나지 않았고 15분 안에 기록이 있음) 반쯤 쓰인 기록이 담기지 않도록 건너뜁니다. 턴이 끝난 뒤 다시 누르세요. 백업하는 사이에 대화가 바뀌어도 같은 이유로 건너뜁니다. 앱이 강제 종료돼 턴이 끝나지 않은 채 남은 대화는 15분이 지나면 백업됩니다.

백업은 하나하나가 따로 암호화된 snapshot이며, 부모 대화와 그 아래 모든 하위 에이전트 대화를 함께 담습니다. 같은 UUID의 백업이 여러 개면 각각 다른 행으로 보이며, GUI가 날짜로 골라 주거나 덮어쓰지 않습니다.

**필터된 대화 모두 백업**은 지금 필터(이 프로젝트 대화만·검색·보기·날짜)에 맞는 이 PC의 대화를 모든 페이지에서 하나씩 백업합니다.
- 시작 전에 백업할 개수와 건너뛸 개수를 보여 주고 확인을 받습니다. Codex 앱은 켜 둬도 되며, 지금 진행 중인 대화는 **진행 중**으로 따로 세고 건너뜁니다. 대화마다 몇 초씩 걸립니다.
- 같은 UUID에 같은 수정 시각의 공유 백업이 이미 있는 대화는 건너뛰므로, 다시 눌러도 바뀐 대화만 새로 올라갑니다. 수정 시각은 묶음에서 가장 늦은 시각이라 하위 대화만 바뀌어도 다시 백업합니다. `이전 형식` 백업은 하위 대화가 없으므로 최신 백업으로 치지 않습니다.
- 한 대화가 실패해도 다음 대화로 넘어가고, 끝에 성공·건너뜀·진행 중·실패 개수와 실패 이유를 보여 줍니다. 저장소에 쓸 수 없는 경우처럼 연속 3개가 실패하면 멈춥니다. 진행 중이라 건너뛴 대화는 실패로 세지 않습니다.
- **작업 취소**를 한 번 누르면 지금 대화를 마친 뒤 멈추고, 한 번 더 누르면 작업 창을 바로 끝냅니다.
- 하나라도 백업되면 목록을 다시 불러와 새 백업을 보여 줍니다.

### 복원

1. 그 대화가 쓸 실제 작업 폴더를 고르고, Drive 앱에서 다운로드가 끝났는지 확인합니다.
2. 공유 백업을 하나 이상 고르고 **미리보기 후 복원**을 누릅니다. 검사하는 동안 로컬 대화 파일과 DB는 바뀌지 않습니다. 다만 엔진 버전을 읽느라 Codex가 `%CODEX_HOME%`(없으면 `%USERPROFILE%\.codex`)의 `tmp\arg0`에 임시 파일을 만들 수 있으며, 이 파일은 Codex가 다음 실행 때 정리합니다.
3. 확인 창에는 이 PC에 없는 대화, 같은 기록, 공유 기록의 연장, 로컬 기록의 연장, 갈라진 기록, 복원할 수 없는 항목이 함께 나옵니다.
   - 모든 행은 **건너뛰기**로 시작합니다. **로컬 유지**도 아무것도 쓰지 않습니다.
   - 복원할 행에서 **공유 백업 복원**을 직접 고릅니다. UUID 하나에는 백업 하나만 고를 수 있습니다.
   - 손상되거나 형식이 맞지 않는 항목에는 복원 선택이 없습니다.
   - 하위 대화가 있으면 묶음 하나로 판단합니다. 하위 대화 하나라도 갈라지면 묶음 전체를 갈라진 기록으로 보고, 복원이나 건너뛰기를 묶음 단위로 고릅니다. 이유 칸에 하위 대화 상태별 개수가 나옵니다.
   - 복원해도 이 PC가 더 최신인 하위 대화와 이 PC에만 있는 하위 대화는 그대로 둡니다.
   - 묶음의 모든 대화는 1단계에서 고른 작업 폴더를 작업 폴더로 씁니다. 하위 대화가 원래 다른 폴더에서 실행됐어도 마찬가지입니다.
4. 선택과 작업 폴더를 확인하고 마지막 승인 창에서 승인합니다. Codex 앱이 실행 중이면 백엔드가 멈추고 앱을 직접 종료하라고 안내합니다. GUI는 Codex·Claude 앱을 강제 종료하지 않습니다. 검사 토큰·백업 파일·ID·데이터 폴더·대상 폴더가 바뀌면 다시 검사해야 합니다.
5. Codex Desktop을 직접 열어 UUID, 대화 내용, 작업 폴더를 확인합니다. GUI는 자동 프롬프트나 CLI 재개 명령을 보내지 않습니다. 프로젝트 파일·Git 상태·도구 설치는 따로 준비합니다.

## 문제 해결

### GUI가 뜨지 않을 때

zip으로 설치했다면 zip을 차단 해제하지 않고 풀었을 가능성이 큽니다. 풀린 폴더를 지우고, zip을 차단 해제한 뒤([설치](#설치) 참고) 다시 풉니다. 설치 파일로 설치했다면 이 문제가 생기지 않습니다. 바로가기를 다시 눌러 보고, 그래도 뜨지 않으면 설치 파일을 다시 실행해 덮어 설치합니다.

### 작업이 실패하거나 멈춘 것 같을 때

- **실패 이유**: ctxhop 명령이 실패하면 오류 창에 종료 코드와 함께 ctxhop이 남긴 이유가 나옵니다(예: 겹친 프로젝트 등록, 암호 불일치). 이유는 `%USERPROFILE%\.ctxhop\logs`(또는 `CTXHOP_CONFIG_DIR` 아래 `logs`)의 그날 로그에서 읽습니다.
- **설정 동기화가 켜져 있을 때**: 백업이 "처음 설정할 때 설정 동기화를 켜서(Y)"라며 멈추면, GUI와 작업 창을 닫습니다. 그다음 메시지에 나온 `config.json`에서 `"syncConfig"` 값을 `"disabled"`로 바꾸고 다시 시도합니다.
- **작업 취소**: 아래쪽 **작업 취소**를 누릅니다. GUI가 띄운 작업 창과 그 안의 ctxhop·Python만 끝내며 Codex·Claude 앱은 건드리지 않습니다. 백업을 취소했다면 다시 백업하세요. **복원과 대화 열기는 취소할 수 없습니다.** 복원은 끝날 때까지 기다리고, 연 대화는 직접 끝냅니다.
- **암호를 잊었거나 바꾸고 싶을 때**: **연결 설정 · 초대** 탭의 **암호 변경**은 현재 암호와 새 암호(두 번)를, **복구 키로 암호 초기화**는 처음 설정 때 받은 복구 키와 새 암호(두 번)를 묻습니다. 둘 다 작업 창에서 실행되며 복구 키는 바뀌지 않습니다.

### Claude 복원이 중단됐을 때

`%LOCALAPPDATA%\CtxHopGUI\recovery`에 `*.pending.json`이 남아 있으면 Claude 백업·복원·열기가 멈춥니다.

1. Claude Code와 VS Code·Cursor 같은 편집기를 모두 닫습니다.
2. `*.pending.json`을 엽니다. `originals`의 각 항목에는 세 값이 있습니다.
   - `original`: 복원 전 대화 파일 경로
   - `backup`: 복구 기록 옆에 만든 사본(`*.original.jsonl`)
   - `sha256`: 사본의 SHA256

   복원 전으로 되돌리려면 `backup` 파일을 `original` 위치에 복사합니다. `originals`가 비어 있으면 이 PC에 없던 대화를 가져오던 중이었으니, 새로 생긴 대화를 Claude Code에서 확인합니다.

   대화 옆 폴더에서 바뀐 파일의 원본은 `companionBackup`에 적힌 `.companion` 폴더에 같은 상대 경로로 있습니다. 되돌리려면 대화 파일 옆 `<세션ID>\` 폴더의 같은 위치로 복사합니다.
3. 확인이 끝나면 `*.pending.json`을 recovery 폴더 밖으로 **옮깁니다**(지우지 않음). 옮기면 차단이 풀립니다.

### Codex 복원이 실패했을 때

실패하면 GUI는 남은 항목을 적용하지 않고, 백엔드가 돌려준 복구 기록(`pending` 폴더 목록)을 보여 줍니다. 원본 백업과 복구 기록은 보존합니다. 중단된 기록이 남아 있으면 이후 백업·복원이 막히므로, **Codex 앱을 종료한 상태에서** GUI 폴더에서 확인하고 복구합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action pending -HomePath 'GUI 설정 탭의 Codex 데이터 폴더'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action recover -HomePath 'GUI 설정 탭의 Codex 데이터 폴더' -Run 'pending에 나온 정확한 폴더'
```

- `-HomePath`는 설정 탭의 Codex 데이터 폴더와 **같은 문자열**이어야 합니다. 끝에 `\`를 붙이지 마세요. `powershell.exe -File`은 끝의 `\'`를 따옴표로 읽기 때문에, 명령이 폴더가 없다며 쓰기 전에 멈춥니다. 이 명령도 GUI와 같은 Python과 고정 백엔드 해시를 씁니다.
- `recover`는 가져오기 전 상태로 되돌립니다. 중단 뒤 앱이 그 대화를 다시 썼거나 DB가 일부만 만들어졌으면 스스로 멈춥니다.
- `recover`는 앱 종료와 DB 구조만 보고 엔진 버전은 보지 않습니다. Codex가 업데이트돼도 DB 구조가 같으면 복구할 수 있고, 다르면 쓰기 전에 멈춥니다. 이때는 다음 항목을 따릅니다(`before.zip` 되살리기는 엔진 버전이 같아야 해서 이 경우 쓸 수 없음).
- **복구가 멈췄거나, 가져오기는 끝났는데 완료 기록만 남았을 때**: 복구를 되풀이하지 말고 Codex 앱에서 그 UUID 대화를 확인합니다. 지금 상태를 유지하려면 `pending`에 나온 폴더를 `.ctxhop-desktop-recovery` 밖으로 **옮깁니다**(지우지 않음). 폴더 안 `before.zip`은 가져오기 전 이 PC의 묶음 전체(부모와 하위 대화), `incoming-0000.zip`처럼 번호가 붙은 파일은 대화별로 가져온 내용입니다. 이전 판이 남긴 복구 폴더에는 `incoming.zip` 하나가 있습니다. 옮기면 차단이 풀립니다.

### 공유 백업으로 덮어쓴 로컬 기록 되돌리기

갈라진 기록에 공유 백업을 복원해도 이 PC의 이전 기록은 하위 대화까지 묶음 전체가 `<Codex 데이터 폴더>\.ctxhop-desktop-recovery\<작업ID>\before.zip`에 남습니다. 그 UUID와 시각의 폴더를 찾습니다. 되살리려면 앱을 종료하고 이 파일을 복원 대상으로 검사한 뒤, 출력된 `token`으로 적용합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action inspect -HomePath 'Codex 데이터 폴더' -Archive '...\before.zip' -Cwd '그 대화의 작업 폴더'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action apply -HomePath 'Codex 데이터 폴더' -Archive '...\before.zip' -Cwd '그 대화의 작업 폴더' -Token '위 출력의 token' -Choice incoming
```

이 적용도 바뀌는 기록을 새 복구 폴더에 남깁니다. 복구 사본에는 복원 당시 이 PC의 엔진 버전이 기록되므로, 그 뒤 엔진이 바뀌었으면 쓰기 전에 차단되고 데이터는 그대로 보존됩니다.

## 참고

### 파일과 폴더

- 선택값: `%LOCALAPPDATA%\CtxHopGUI\vnext-preferences.json`
- 임시 작업 요청·결과: `%LOCALAPPDATA%\CtxHopGUI\jobs`
- Codex 백업·검사 파일: `%LOCALAPPDATA%\CtxHopGUI\staging\고유ID`
  - 작업마다 현재 사용자만 열 수 있는 새 폴더를 만듭니다.
  - 백업 업로드나 복원이 성공하면 그 작업의 평문 사본을 지웁니다.
  - 실패하거나 취소한 작업과 건너뛴 미리보기의 폴더는 복원 토큰과 실패 증거로 남습니다. 필요 없으면 직접 지웁니다.
  - 이 폴더의 평문 대화는 Drive에 올리지 마세요.
- Claude 복구 기록: `%LOCALAPPDATA%\CtxHopGUI\recovery`
- Codex 복구 기록: `<Codex 데이터 폴더>\.ctxhop-desktop-recovery`
- ctxhop 설정과 로그: `%USERPROFILE%\.ctxhop`(또는 `CTXHOP_CONFIG_DIR`)

GUI는 세션 폴더나 DB 전체를 통째로 덮어쓰지 않습니다.

### 무결성 검사

- `Worker.ps1`은 `backend\desktop_sessions.py`와 `bin\ctxhop.exe`의 SHA256을 고정해 두고, Codex 목록·백업·미리보기 전에 확인합니다. 파일이 없거나 바뀌면 멈춥니다.
- `bin\ctxhop-claude.exe`는 Claude 미리보기·복원 전에 고정한 `0.2.0-gui.2` 해시와 같아야 합니다. `0.2.0-gui.1`에 대화 옆 폴더 백업·복원(`--sidecar-backup`)을 더한 판이며, 소스·패치·빌드 기록은 `claude-source\`에 있습니다.
- `ClaudeWorker.ps1`은 안정판 `ctxhop-gui`의 Worker(SHA256 `D08E9A15…`)를 복사한 것입니다. 여기에 언어 적용, 실패 이유 표시, 겹친 등록 차단, 등록 해제, 암호 변경·초기화를 더했습니다. 백업·복원 판단과 복구 기록 동작은 바꾸지 않았습니다.
- `Worker.ps1`은 고정한 Python 백엔드와 `bin\ctxhop.exe`의 `bundle` 명령을 연결합니다. UI는 대화 본문·DB·압축 형식을 직접 해석하지 않습니다.
- 화면과 작업 메시지의 한국어·영어 문장은 `Strings.ps1`에 `키=@('한국어','English')`로 모여 있습니다.
- Codex Desktop이 새 엔진 버전으로 업데이트되면 `backend\test_suite.py`로 다시 검증한 뒤 `VERSIONS`에 추가해야 합니다.

### 격리 검사

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-ClaudeWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-ClaudeGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-DesktopGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-Strings.ps1
& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" -X utf8 .\backend\test_suite.py --exe '설치된 Desktop codex.exe 절대경로'
```

- 앞의 네 개는 새 임시 폴더와 합성 메타데이터를 쓰며, 백엔드·전송·Codex·Claude 실행을 mock으로 대신합니다.
- `Test-DesktopIntegration.ps1`은 설치된 Codex Desktop 엔진으로 임시 폴더에 시험 대화를 만든 뒤, **고정한 실제 백엔드**를 Worker로 호출합니다. 전송만 mock입니다.
- `Test-Strings.ps1`은 두 언어 문장의 짝과 자리표시자를 확인합니다. 코드에 남은 번역 안 된 한글과 영어 화면·오류 메시지도 봅니다.
- `backend\test_suite.py`는 격리한 `CODEX_HOME`과 localhost 고정 응답으로 실제 엔진의 paginated 대화를 만들고 이식·읽기·재개를 확인합니다.

결과와 해시는 `verification.md`에 있습니다. 이 후보를 만들고 시험하는 동안 프로덕션 저장소, 실제 사용자 세션, 인증 설정, 전역 실행 정책은 바꾸지 않았습니다.
