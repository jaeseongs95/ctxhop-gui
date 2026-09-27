# vNext 통합 검증 기록 (2026-09-26, DESKTOP-DKTCA33)

노트북 세션의 GUI·전송 후보(`ctxhop-gui-vnext`)와 데스크톱 세션의 Codex Desktop 백엔드(`ctxhop-desktop-next`)를 합친 최종 후보입니다. 두 원본 세션은 Codex 사용량 한도로 통합 직전에 중단됐습니다.

## 통합하면서 고친 것

| 항목 | 문제 | 조치 |
|---|---|---|
| 백엔드 미포함 | `backend\` 폴더가 없고 Worker의 백엔드·Python SHA 고정값이 비어 있어 Codex 경로가 항상 중단됨 | `backend\`에 백엔드·스키마·시험 파일을 넣고 백엔드 SHA를 고정 |
| 엔진 업데이트 | 이 PC의 Codex Desktop이 17:26에 `0.158.0-alpha.2.1`로 업데이트됨. 백엔드는 `alpha.2` 문자열과 정확히 비교해 내보내기·가져오기를 모두 차단 | 실제 DB 구조를 읽기 전용으로 비교(state 마이그레이션 57개·history 7개, 객체 전부 일치) → 격리 native 시험 통과 후 `VERSIONS`에 추가. 내보낼 때 실제 엔진 버전을 기록 |
| 엔진 버전 일치 | 허용 목록만 확인하면 서로 다른 버전 PC 사이 이식이 시험 없이 허용됨(원래 계약: 버전 정확 일치) | 미리보기(`inspect`)와 복원(`apply`) 모두 백업의 엔진 버전과 이 PC 엔진 버전이 다르면 쓰기 전에 차단. 미리보기에서 "새 대화"로 보였다가 복원에서야 막히는 일이 없음 |
| 앱 종료 검사 | 종료 검사 대상 프로세스 이름에 `ChatGPT.exe`가 없음(2차 감사 지적) | 검사식에 `ChatGPT` 추가 |
| 하위 에이전트 대화 | 백엔드는 하위 에이전트 대화(`source`가 `{"subagent":…}`)를 단독으로 내보내지 않는데 목록에서는 일반 대화처럼 보여 백업을 눌러야 실패함. 이 PC 실제 대화 3,071개 중 1,506개(읽기 전용 집계) | 백엔드 `list`가 `subagent` bool을 반환하고, Worker가 해당 행을 숨기지 않고 "작업 불가: 하위 에이전트 대화는 따로 백업할 수 없습니다. 부모 대화를 선택하세요."로 표시 |
| 목록 형식 | 백엔드 `list`가 `updatedAt`을 epoch 정수(예: `1790417799`), `archived`를 `0/1`로 반환. Worker는 `archived`가 bool이 아니면 목록 전체를 실패시킴 → 실제 백엔드로는 Codex 목록이 열리지 않았음(기존 테스트는 mock이라 발견되지 않음) | 백엔드에서 UTC RFC3339 문자열과 bool로 반환 |
| 제목 줄바꿈 | 전송 메타데이터는 NUL·줄바꿈을 거부하는데 백엔드가 제목을 그대로 넘김. 이 PC 실제 대화 3,071개 중 31개가 백업 불가(독립 감사 F1, 읽기 전용 집계) | 메타데이터 제목의 `\0` `\r` `\n`을 공백으로 바꿈. 대화 내용은 그대로 |
| 오류 전달 | 백엔드는 실패 이유를 stdout JSON `reason`에 쓰는데 Worker는 `error`만 읽어 "작업 실패 (종료 코드 1)"만 표시 | Worker가 `reason`을 먼저 읽음 |
| 결과 표시 | 백엔드가 `equal`/`local_newer`로 아무것도 쓰지 않아도 "복원 완료"로 표시 | 결과별로 "복원 완료"와 "변경 없음"을 나눠 표시 |
| 실패 뒤 복구 | `apply` 실패 결과에 중단 기록 위치가 없음. 복구 중 남은 `journal.tmp`가 있으면 완료 기록이 매번 실패 | 실패 JSON에 `pending` 폴더 목록 추가, 임시 파일은 덮어씀. README에 `-HomePath`와 복구가 멈췄을 때의 수동 절차 기재 |
| 실행 정책 | 백엔드가 `powershell -ExecutionPolicy Bypass -File Assert-Closed.ps1` 호출(안정판의 "Bypass 자동 추가 금지" 계약과 충돌) | 같은 검사식을 백엔드 안의 고정 `-EncodedCommand`로 실행. 별도 스크립트 파일 삭제, 검사식은 백엔드 SHA에 포함 |
| Python 고정 | Worker가 Python 실행 파일 SHA 하나를 요구. Codex가 관리·갱신하는 런타임이고 두 PC의 사용자 경로도 달라 한 값으로 고정 불가 | Codex 번들 런타임 기본 경로 + PC별 `backend\runtime.json` 선택. PATH·자동 설치 없음. 백엔드에서 Python 3.10 미만 차단. 원래 설계와 달라 사용자에게 확인받음(수용) |
| 문서 누락(3차 감사) | 미리보기의 엔진 확인이 `tmp\arg0`에 임시 파일을 만드는데 GUI는 "읽기 전용"으로 안내. 엔진 업데이트 뒤 `recover` 차단, 갈라진 기록을 공유 백업으로 덮은 뒤 로컬 기록(`before.zip`)을 되살리는 방법이 문서에 없음 | GUI 설정 탭 문구를 "대화 파일과 DB를 바꾸지 않습니다"로 수정. README에 세 경우를 기재하고, 되살리기 절차(`inspect` → `apply`)는 `test_23`으로 CLI 경로를 확인 |
| 테스트 경로 의존 | `Test-DesktopWorker.ps1`이 형제 폴더 `..\ctxhop-gui\Worker.ps1`과 비교, mock이 백엔드에 없는 상태값 `applied` 사용 | 안정판 최종 감사 해시 `D08E9A15…`와 직접 비교, mock을 실제 값 `imported`로 |

## 전체 점검 뒤 보완 (5차 감사 이후)

| 항목 | 문제 | 조치 | 확인 |
|---|---|---|---|
| 복구 사본 엔진 표시 | `before.zip`에 실제 엔진이 아니라 지원 목록의 마지막 버전(`alpha.2.1`)이 기록돼 `alpha.2` PC에서는 로컬 기록 되살리기가 항상 차단됨(4차 감사 재현) | `apply`가 앱 종료 검사에서 얻은 이 PC 엔진 버전을 `before.zip`에 기록 | `test_24` |
| 엔진 업데이트 뒤 복구 | `recover`가 지원 엔진 목록까지 요구해, 실패 뒤 Codex가 업데이트되면 DB 구조가 같아도 복구가 막히고 그동안 모든 백업·복원이 차단됨 | `recover`는 앱 종료 검사와 고정 DB 구조 검사만 사용(이 PC의 이전 상태로 되돌리는 작업이라 엔진 버전 대신 구조로 호환 확인). 구조가 바뀌었으면 쓰기 전에 멈춤 | `test_25`(지원 밖 엔진에서 복구 성공, 구조 변경 시 차단·pending 유지) |
| 평문 사본 누적 | 백업·복원마다 평문 대화 사본이 `%LOCALAPPDATA%\CtxHopGUI\staging`에 영구히 남음 | 백업은 업로드 성공 뒤, 복원은 적용 성공 뒤 그 작업의 `staging\<GUID>` 폴더에서 알려진 파일(`session.archive`·`metadata.json`·`inspect.json`)만 지우고 빈 폴더를 삭제(재귀 삭제·링크 추적 없음). 다른 폴더·모르는 파일·링크 폴더는 건드리지 않고, 삭제 실패는 작업 실패가 아니라 결과 문구의 경고로 알림(6차 감사 F1·F2). 실패한 작업은 증거로 유지 | `Test-DesktopWorker`(연결 폴더 거부 포함, 7차 감사 N1)·`Test-DesktopIntegration` |
| 수동 복구 명령 | `backend\Invoke-Desktop.ps1`이 백엔드 SHA·`runtime.json`·Python `-I`를 쓰지 않고 `$env:CTXHOP_PYTHON`을 읽음. PowerShell 5.1의 인자 전달로 공백과 끝 `\`가 있는 경로가 깨질 수 있음 | Worker를 라이브러리로 불러 같은 고정 백엔드·Python 선택·`-I`·인자 인용(`Invoke-DesktopBackend`)을 사용. 결과는 JSON으로 출력, 실패 시 종료 코드 1. `powershell.exe -File`의 바깥 인자 경계에서 끝 `\`가 깨지는 문제는 PowerShell 자체 동작이라 README에 "끝에 `\`를 붙이지 말 것"으로 안내(6차 감사 F4) | `Test-DesktopIntegration`(변조한 백엔드 거부, PowerShell 안에서 `&`로 호출할 때 공백·끝 `\` 경로 전달) |
| 복구 중 구조 재확인 | `recover`가 쓰기 잠금 전에만 DB 구조를 확인(6차 감사 F5) | 잠금(`BEGIN IMMEDIATE`) 안에서 `check_schema`를 한 번 더 실행 | `test_26`(첫 검사와 잠금 사이 구조 변경 시 차단, 7차 감사 N2) |
| zip 경로 구분자 | `Compress-Archive`가 역슬래시 경로로 저장 | .NET `ZipFile.CreateFromDirectory`로 만들어 `/` 경로로 저장 | zip 항목 검사 |

## GitHub PR 검토 중 고친 것

| 항목 | 문제 | 조치 | 확인 |
|---|---|---|---|
| Worker 결과 파일 | GUI가 띄운 `Worker.ps1`이 `ClaudeWorker.ps1 -LibraryOnly`를 dot-source하면 ClaudeWorker의 `param` 블록이 같은 스코프의 `$RequestFile`·`$ResultFile`을 빈 값으로 다시 묶음. 요청을 읽지 못하고 결과 파일도 쓰지 못해 GUI의 모든 작업이 "작업 창이 중단되었습니다"로 끝남. 기존 시험은 Worker를 라이브러리로만 불러 이 경로를 실행하지 않았음(언어 선택 작업 중 발견) | dot-source 전에 두 경로를 보관했다가 되돌림 | `Test-DesktopWorker`가 GUI처럼 Worker를 별도 프로세스로 실행해 결과 파일을 확인. 수정 전 Worker에서는 실패 |
| macOS CI | `internal/desktopbundle`의 경로 검사가 상위 폴더의 모든 링크를 거부하는데(의도한 보안 동작), macOS 임시 폴더 `/var`가 `/private/var` 링크라 bundle 시험 11개가 실패 | 제품 검사는 그대로 두고, 시험이 링크를 푼 임시 폴더(`filepath.EvalSymlinks`)를 쓰도록 수정 | GitHub CI |

## 언어 선택 (한국어·English)

- 설정 탭에 **Language / 언어** 선택(한국어, English)을 추가했습니다. 선택은 `vnext-preferences.json`의 `language`에 저장되고 다시 시작하면 적용됩니다. 작업 요청에도 `language`가 실려 작업 창(`Worker.ps1`)의 메시지가 같은 언어로 나옵니다.
- GUI·Codex Worker·Claude Worker의 화면·오류 문장 229개를 `Strings.ps1`(`키=@('한국어','English')`)로 옮겼습니다. 한국어 문장은 원래 문자열과 같아서 기존 시험이 그대로 통과합니다.
- 번역하지 않은 것: Python 백엔드의 차단 사유, ctxhop·Codex·Claude 실행 파일 출력, 글꼴 이름과 기본 Drive 경로.
- `ClaudeWorker.ps1`은 안정판(`D08E9A15…`)과 더 이상 바이트가 같지 않습니다.
  - 바뀐 것: 문장을 `T '키'` 호출로 바꾼 것, `Strings.ps1`을 불러오는 줄, 요청의 언어를 적용하는 `Set-Language` 줄. 판단·분기 논리는 그대로입니다.
  - `Test-DesktopWorker`는 이 판의 해시를 고정합니다.
- 수동 복구 진입점 `backend\Invoke-Desktop.ps1`은 언어를 받지 않아 오류 문장이 항상 한국어입니다.
- 저장소에 있는 `gui-*-preview.png`는 이번에 다시 그리지 않아 언어 선택이 보이지 않습니다. 영어·한국어 화면은 격리 스크린샷으로 따로 확인했습니다.
- `Test-Strings.ps1`(신규)이 확인하는 것:
  - 두 언어 문장의 짝과 자리표시자
  - 세 스크립트에 남은 번역 안 된 한글(주석 제외)
  - 쓰이지 않거나 없는 키
  - 영어 화면(글자 넘침은 스크린샷으로 따로 확인)
  - 영어 선택 값으로 복원 결정
  - 별도 프로세스로 띄운 작업 창이 요청 언어로 답하는지
- 목록을 그릴 때 행마다 문장을 찾지 않도록 반복문 밖에서 한 번만 찾습니다(5,000개 첫 표시: 이번 실행들 133~187ms, 이전 기록 201ms).

## 사용성 개선 (2026-09-27)

사용자가 Codex 대화를 백업하다 목록이 계속 실패한 일을 계기로 GUI 동작을 전수 조사했습니다.

- **원인**: 작업 PC의 ctxhop 오류 기록·로그·`config.json`을 읽기만 해서 확인했습니다. 상위 폴더(`D:\codex`, `Documents\Codex`)와 하위 폴더가 서로 다른 공통 이름으로 등록된 뒤부터 그 안의 목록 불러오기와 재등록이 모두 `current directory has conflicting project bindings`로 실패했습니다.
  - 격리 폴더에서 `ctxhop 0.2.0-gui.1`로 같은 순서를 재현했습니다.
  - 상위 등록을 `project unbind`로 해제하면 다시 목록이 나오는 것을 확인했습니다.
  - 해제로 바뀌는 파일은 `config.json`뿐입니다(저장소와 registry는 그대로).
- **암호**: 격리 폴더에서 `0.2.0`·`0.2.0-gui.1`로 설정한 PC는 목록(`list`)과 Codex bundle 올리기·목록·내려받기에서 암호를 묻지 않았습니다(입력을 닫은 채 성공). 설정 중 암호 불일치나 복구 키 확인 실수는 아무것도 남기지 않아 다시 설정하면 성공합니다. 실제 문제는 실패 이유가 GUI에 보이지 않는 것이었습니다.
- **바꾼 것**:
  - 상위·하위 폴더를 다른 공통 이름으로 등록하면 ctxhop 호출 전에 막습니다(`Assert-NoBindingOverlap`). 같은 폴더를 다른 이름으로 다시 등록하는 경우는 ctxhop이 직접 거부합니다.
  - **등록 해제** 버튼(`project unbind`)을 추가했고, 등록·해제 뒤 등록된 프로젝트 목록을 다시 읽습니다. ctxhop은 `--path`의 폴더를 직접 확인하므로, 지워진 폴더는 그 공통 이름의 등록이 이 경로 하나뿐일 때만 이름(`--identity`)으로 해제합니다.
  - 등록이 하나도 없어 `config.json`에 `bindings`가 없는 PC에서도 첫 등록이 됩니다(독립 감사 F1).
  - ctxhop 명령이 실패하면 그날 ctxhop 로그에서 같은 명령의 실패 줄을 찾아 이유를 오류에 붙입니다(`Get-CtxFailureReason`). 작업 시작 시각 이후 줄만 보고, 따옴표 없이 적힌 값도 읽습니다. 다른 ctxhop이 로그를 연 채여도 공유 읽기로 읽고, 못 읽으면 종료 코드만 보입니다(F6).
  - **작업 취소**를 목록 외 작업으로 넓혔습니다. GUI가 띄운 작업 창의 프로세스 트리만 끝내며 이름으로 프로세스를 찾지 않습니다. 복원과 대화 열기는 취소할 수 없습니다.
    - 프로세스 표를 한 번만 읽어 부모부터 끝냅니다. Windows는 부모가 끝나도 `ParentProcessId`를 그대로 두고 PID를 재사용하므로, 부모보다 먼저 생긴 "자식"은 다른 프로그램으로 보고 건드리지 않습니다(F2·F4).
    - 취소 확인 창이 떠 있는 동안 작업이 끝났으면 아무것도 끝내지 않습니다(F5).
  - 설정 탭에 **암호 변경**·**복구 키로 암호 초기화**(`passphrase change`·`reset`, 보이는 작업 창)를 추가했습니다.
  - 창 크기 조절(최소 1096×675)을 추가했습니다. 화면 작업 영역보다 크면 시작할 때 줄이고, 설정 탭은 스크롤합니다. 탭 페이지는 핸들이 생겨야 실제 크기가 되므로 Anchor 전에 핸들을 만듭니다.
  - Codex 복원 확인 창: 크기 조절, 행 높이 자동, 백업 ID 별도 열, 항목 수를 표시합니다.
  - 목록: 날짜를 이 PC 시간(`yyyy-MM-dd HH:mm`)으로 표시하고, 세션 UUID가 잘리지 않게 했습니다. 여러 개를 고르면 "N개 선택"으로 표시합니다.
  - 버튼 툴팁을 추가했습니다. 꺼진 버튼은 툴팁이 뜨지 않으므로 탭과 창 위에서 대신 띄웁니다(F9).
  - 안내 문구: 실행 중인 프로그램 이름·PID, 보이는 창·숨은 창별 처리 중 문구, 설정 동기화 `[Y/n]` 기본값 Y 경고와 되돌리는 방법(실제 설정 폴더 경로로 안내), README의 "Claude 복원이 중단됐을 때" 절차.
- `Worker.ps1`, 백엔드, `bin\*.exe`는 바꾸지 않았습니다. `ClaudeWorker.ps1`의 백업·복원 판단과 복구 기록 동작은 그대로입니다.
- 시험이 다시 그리는 `gui-settings-preview.png`, `gui-desktop-conflicts-preview.png`를 새 화면으로 갱신했습니다.
- **제한**:
  - 실패 이유는 ctxhop 로그 형식(`time=… level=ERROR msg=command_finished command=… error="…"`)에 기대고, 자정을 넘긴 작업은 종료 코드만 보입니다.
  - 확인 창의 백업 ID·UUID·경로처럼 공백 없는 긴 값은 칸 안에서 잘립니다. 행을 고르면 아래 상세 칸, 칸에 마우스를 올리면 툴팁에 전체가 나옵니다.
  - 실제 125/150% 배율 화면은 확인하지 않았습니다.
  - 같은 순간 다른 ctxhop(예: hook의 `push`)이 같은 명령으로 실패하면 그 이유가 붙을 수 있습니다(F6).
  - 겹침 검사는 입력한 경로 기준입니다. ctxhop은 Git 최상위 폴더를 등록하므로, 그 아래 다른 중첩 저장소 등록과의 겹침은 GUI가 놓치고 ctxhop이 거부합니다. 데이터는 바뀌지 않습니다(F7).
  - 취소한 Codex 백업의 평문 사본은 `staging`에 남고, 공유 저장소에는 목록에 보이지 않는 chunk만 남을 수 있습니다(F8). Claude `push`를 중간에 끊었을 때의 원자성은 확인하지 않았습니다.
- **독립 감사**: 첫 감사는 FAIL(F1 빈 `bindings`에서 등록 실패, F2 PID 재사용으로 다른 프로그램 종료 가능)이었습니다. F1~F6·F9를 고치고 F7·F8은 위 제한으로 적었습니다.

## 실행한 검사 (Windows PowerShell 5.1, Python 3.12.14 Codex 번들, 엔진 `0.158.0-alpha.2.1`)

| 검사 | 결과 | 원시 로그 |
|---|---|---|
| `backend\test_suite.py` (일반·위험 원본 정책 2회, 각 run마다 native probe + 단위 시험) | 각 26/26 통과, `ok: true` | `..\검증자료\suite-492977b8b2d04583aeed9be12a84659d\` |
| `Test-DesktopIntegration.ps1` (고정한 실제 백엔드. 차단 경로 + 시험 전용 진입점을 쓴 백업→전송→미리보기→복원→재검사 성공 경로, 엔진 불일치 미리보기 차단, staging 정리, 수동 진입점) | 32 assertions 통과 | `..\검증자료\ps51-r6\Test-DesktopIntegration.txt` |
| `Test-DesktopWorker.ps1` | 59 assertions 통과. Worker 결과 파일 수정 뒤 61 assertions 통과 | `..\검증자료\ps51-r6\Test-DesktopWorker.txt` (수정 뒤 실행은 PR 브랜치에서) |
| `Test-DesktopGUI.ps1` | 25 assertions 통과 | `..\검증자료\ps51-r6\Test-DesktopGUI.txt` |
| `Test-ClaudeWorker.ps1` | 37 groups, 640 assertions, 0 failures | `..\검증자료\ps51-r6\Test-ClaudeWorker.txt` |
| `Test-ClaudeGUI.ps1` | 93 assertions, 5,000개 합성 목록 첫 표시 201ms | `..\검증자료\ps51-r6\Test-ClaudeGUI.txt` |

PowerShell 시험은 `powershell.exe -NoProfile -ExecutionPolicy Bypass [-STA] -File`로 실행했고 5개 모두 종료 코드 0이었습니다(각 로그 끝에 `EXIT CODE` 기록, README의 `RemoteSigned`로는 다시 실행하지 않음).

언어 선택 뒤 같은 명령으로 6개를 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1219, `Test-DesktopWorker` 61, `Test-DesktopGUI` 25, `Test-ClaudeGUI` 93(5,000개 첫 표시 143ms), `Test-ClaudeWorker` 640 assertions, `Test-DesktopIntegration` 32. 이 실행의 원시 로그는 작업 PC의 임시 폴더에만 있습니다.

사용성 개선 뒤 같은 명령으로 6개를 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1337, `Test-DesktopWorker` 61, `Test-DesktopGUI` 26, `Test-ClaudeGUI` 113(5,000개 첫 표시 153ms), `Test-ClaudeWorker` 40 groups·655 assertions, `Test-DesktopIntegration` 32. 원시 로그는 작업 PC의 임시 폴더에만 있습니다.

감사 지적을 고친 뒤 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1342, `Test-DesktopWorker` 61, `Test-DesktopGUI` 27, `Test-ClaudeGUI` 115, `Test-ClaudeWorker` 41 groups·672 assertions, `Test-DesktopIntegration` 32.

폴더 선택 오류를 고친 뒤 6개를 `powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File`로 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1342, `Test-DesktopWorker` 61, `Test-DesktopGUI` 27, `Test-ClaudeGUI` 119, `Test-ClaudeWorker` 41 groups·672 assertions, `Test-DesktopIntegration` 32. 고친 문제는 칸이 비었거나 잘못된 문자가 든 경로에서 **폴더 선택** 세 곳과 **다른 PC용 초대 만들기**가 `LiteralPath` 또는 `Illegal characters in path` 오류를 내던 것과, 공백만 든 칸을 대화 상자의 시작 폴더로 넘기던 것입니다. 새 `Test-ClaudeGUI` 검사는 네 버튼을 빈 칸·공백·`a|b`로 눌러 보며, 이전 검사식으로 되돌린 변이 사본에서 실패합니다.

- 전송(`bin\ctxhop.exe`)은 PowerShell 테스트에서 mock이고, 성공 경로의 mock은 bundle 메타데이터 규칙(정확한 7개 필드, BOM 없음, NUL·줄바꿈 없음)을 확인합니다.
- `backend\test_guard_shim.py`는 시험 전용이며 앱 종료 검사와 엔진 버전 조회만 바꿉니다(엔진은 환경변수 값). Worker·GUI는 이 파일을 호출하지 않습니다. `Test-DesktopIntegration.ps1`의 성공 경로를 다른 PC에서도 다시 돌릴 수 있도록 패키지에 남겨 두었습니다.
- native 시험은 격리 `CODEX_HOME`과 localhost 고정 응답만 사용했고 외부 모델 호출은 없습니다. 검사 뒤 `%USERPROFILE%\.ctxhop`, 공유 `v1\keyfile`의 수정 시각이 이전과 같고, `%LOCALAPPDATA%\CtxHopGUI`와 임시 fixture가 남지 않은 것을 확인했습니다. PowerShell 7은 이 PC에 없어 실행하지 않았습니다.
- 이전 일곱 판(백엔드 `6AE2432C…`, 패키지 zip `04B80957…`, `6E48C2C2…`, `3ACC8589…`, `F0797242…`, `0A16B4CB…`, `8FAD77C3…`)에 대한 독립 감사는 모두 Gate PASS(차단 결함 없음)였습니다. 위 표의 제목 줄바꿈·버전 일치·복구 임시 파일·결과 표시·성공 경로 시험(1차), 미리보기 엔진 차단·`ChatGPT.exe`·하위 에이전트 표시(2차), 문서 누락(3차), 되살리기 조건·`arg0` 위치·엔진 업데이트 안내 문구(4차), staging 삭제 안전화·수동 진입점 변조 시험·끝 `\` 안내·복구 잠금 안 구조 재확인(6차), 연결 폴더 거부·잠금 안 재확인 시험(7차)은 그 감사의 비차단 발견사항을 반영한 것입니다. `F0797242…` 이후 바뀐 파일은 `backend\desktop_sessions.py`, `backend\Invoke-Desktop.ps1`, `backend\test_desktop_sessions.py`(`test_24`·`test_25`), `backend\test_guard_shim.py`, `Worker.ps1`, `Test-DesktopWorker.ps1`, `Test-DesktopIntegration.ps1`, `README.md`, `verification.md`, 그리고 시험이 다시 그리는 `gui-*-preview.png`입니다. 7차 감사(`8FAD77C3…`)와 패키지 zip 사이에는 시험 두 개(`test_26`, `Test-DesktopWorker`의 연결 폴더 거부)와 이 문서만 바뀌었고, 두 시험은 보호 장치를 뺀 변이 사본에서 실패하는 것을 확인했습니다. 그 뒤 GitHub PR에서 고친 것과 언어 선택은 위의 두 절에 있으며, 각각 별도 독립 감사에서 Gate PASS를 받았습니다.
- 사용자 결정(2026-09-26): Python 실행 파일 SHA 고정 제거를 수용, 시험 전용 `test_guard_shim.py`는 패키지에 유지.

## 설치 파일

`installer\CtxHop-GUI-vNext.iss`(Inno Setup 6.7.3)로 만듭니다. 사용자별 설치(`%LOCALAPPDATA%\Programs\CtxHop GUI vNext`, 폴더 선택 화면 없음), 64비트 Windows만, GUI 작업이 잡은 `CtxHopGUI-operation` mutex가 있으면 설치·제거를 멈춤, 실행 중인 프로그램을 닫지 않음, 바로가기와 설치 뒤 실행은 System32의 Windows PowerShell을 최소화 상태로 직접 실행합니다. 첫 판(`20260927`)이 32비트 모드였으므로 같은 모드를 유지해 덮어 설치해도 제거 기록이 하나로 남습니다.

이 PC에 실제로 설치된 판을 건드리지 않도록, 시험은 AppId와 이름만 바꾼 시험용 빌드로 했습니다(`TEST` 이름, 나머지 설정 동일). 결과:

- 첫 판 방식의 시험용 빌드 위에 새 판을 `/DIR` 없이 덮어 설치: 이전 폴더를 그대로 쓰고, 앱 목록 버전은 `2026.09.27.1`, 제거 프로그램은 `unins000` 하나, 패키지 파일 437개가 해시까지 같고, 인터넷 출처 표시(Zone.Identifier)가 없음. 사용자가 만든 `backend\runtime.json`은 유지.
- 설치된 복사본에서 시험 6개를 `RemoteSigned`로 실행해 모두 통과.
- mutex를 잡은 동안 설치와 제거는 종료 코드 1로 멈추고 파일을 바꾸지 않음. 대화형으로 실행하면 "CtxHop GUI 작업이 진행 중입니다… 작업이 끝난 뒤 확인을 누르세요" 안내 창을 띄우며, 취소하면 아무것도 바꾸지 않습니다(한국어·English 확인). GUI 창을 닫아도 작업 창(Worker)이 끝날 때까지 이 안내가 나옵니다.
- 앱 목록의 버전은 첫 판과 같은 형식(`2026.09.27.1`)입니다. Setup을 관리자 권한으로 실행하면 마지막 화면의 실행 선택지를 보이지 않게 해 GUI가 관리자 권한으로 뜨지 않게 했습니다(관리자 권한 실행 자체는 시험하지 않음).
- 제거 뒤 앱 목록 항목과 바로가기가 사라지고 설치 폴더에는 `backend\runtime.json`만 남음. 인터넷 출처 표시를 붙인 설치 파일로 새로 설치해도 설치된 파일에 표시가 없음.
- 설치 마법사(한국어·English)는 추가 작업(바탕화면 바로가기, 기본 선택) → 준비 → 완료(실행, 기본 선택) 세 화면입니다. 완료 뒤 실행한 GUI는 64비트 PowerShell에서 최소화되지 않은 창으로 떴고 콘솔 창은 보이지 않았습니다.
- 바로가기 방식 비교(Windows 11 25H2, 기본 터미널 설정 없음): `.cmd`를 여는 바로가기는 Windows Terminal 창이 잠깐 보였고, PowerShell을 최소화로 직접 여는 바로가기는 콘솔 창이 한 번도 보이지 않았습니다.
- 덮어 설치·제거 시험 전후로 `%LOCALAPPDATA%\CtxHopGUI`와 실제 설치본은 바뀌지 않았습니다. 마법사 시험에서 띄운 GUI는 시험 폴더를 `LOCALAPPDATA`로 써서 설정을 거기에 저장했습니다.

설치 파일은 서명이 없어 SmartScreen 경고가 뜰 수 있으며, 실제 SmartScreen 창과 다른 PC 설치는 확인하지 않았습니다.

## 고정 해시 (SHA-256)

| 파일 | SHA-256 |
|---|---|
| `backend\desktop_sessions.py` (Worker 고정) | `C47841453AFB902CE9C409062C5F645359BD26654186F292D182BDD1E53115BE` |
| `backend\Invoke-Desktop.ps1` (수동 복구 진입점) | `563FA5BD89A24D4FB12C176BF199143A76E399CFD5FBDD107DD2A5490B3A789A` |
| `backend\schema.json` (백엔드 고정) | `D24ACAC2105569B5B9CFDABC5259DB8217B9A9F175D7D2B57A09A2D4F76FA0A2` |
| `bin\ctxhop.exe` (bundle 전송, Worker 고정, 변경 없음) | `9B14CCD3B33C75EDFD9D424D76FBAF17092364C58721C1BB9C0FD6BA73C7C006` |
| `bin\ctxhop-claude.exe` (`0.2.0-gui.1`, 변경 없음) | `A1702CE1839AF90C0DDB87E7C07F1BE7899BE8EBDD9117FE680D2EC9739C233D` |
| `ClaudeWorker.ps1` (안정판 `D08E9A15…`에서 문장을 `Strings.ps1`로 옮기고 언어 적용·실패 이유·겹친 등록 차단·등록 해제·암호 변경/초기화 추가) | `97405AABD4B533974D070CA6F7A69B1C1CE537F094489D4924FC32F1F8977823` |
| `Worker.ps1` (결과 파일 경로 보관 수정, 언어 선택) | `C8AA63D2F8F853A77B5AD48F6E74468E777FA3EDF76C8DF5AC0539F81FE59EA8` |
| `GUI.ps1` (언어 선택, 사용성 개선, 폴더 선택 빈 칸 오류 수정) | `507B9BF23CBC4CED31568F2B76AD3DE4044E842B865424F7D4A54D5FCD1F04CC` |
| `Strings.ps1` (한국어·영어 문장 표) | `E04493D126B9EEBEE2A8A4B56C6A42B814E01766DB70FFCD634483382A4BE75A` |

`transport-source\`와 `bin\ctxhop.exe`는 노트북 세션 결과를 그대로 옮겼습니다. 이 PC에는 Go가 없어 Go 시험을 다시 실행하지 않았고, 기록된 결과(`transport-source\verification-results\`: 전체 suite 통과, race는 gcc 부재로 미실행)를 근거로 둡니다.

## 남은 제약

- **두 PC 실제 왕복 미실행**: 실제 사용자 대화의 백업→Drive→복원→앱 화면 확인은 실행하지 않았습니다. 이 PC에서 Codex 앱이 실행 중이라 실제 앱 종료 검사를 통과하는 CLI 성공 경로도 실행하지 않았고, 같은 코드는 guard를 바꾼 시험으로만 확인했습니다. 새로 가져온 세션이 Desktop 앱 사이드바에 보이는지도 확인하지 못했습니다.
- 두 PC의 Codex Desktop 엔진 버전이 같아야 가져올 수 있습니다. 첫 왕복 전에 노트북 버전을 확인하세요.
- 두 SQLite DB와 세션 파일의 원자적 갱신은 보장하지 않으며, 중단 기록과 선택 세션 원본으로 복구합니다. 복구가 멈추는 경우는 README의 수동 절차를 따릅니다(GUI 복구 화면 없음).
- 동적 도구가 등록된 세션, 알 수 없는 DB 구조, 지원하지 않는 엔진 버전은 차단합니다. 하위 에이전트 대화는 단독 백업이 안 되며 부모 대화를 백업해야 합니다(부모 백업에 하위 대화가 함께 들어가는지는 확인하지 않았음). 이 PC 실제 목록 기준으로 하위 에이전트가 아닌 대화 1,565개 중 1,528개가 백업 가능하고, 나머지는 동적 도구 30·경로 불일치 3·레코드 크기 2·1GiB 초과 1·`session_id` 1로 차단됩니다(2차 감사의 읽기 전용 집계).
- 앱 종료 검사는 프로세스 이름으로 모든 Codex 실행 파일을 막지만, 버전 확인은 `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe` 중 최신 파일만 봅니다. 이 PC에는 `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`(`0.155.1`, 다른 앱이 실행)도 있고 같은 `~\.codex`를 씁니다. 실행 중이면 종료 검사가 막지만, 복원 뒤 이 엔진이 가져온 대화를 열면 버전 차이의 영향은 시험하지 않았습니다.
- 가져오기 중 DB 파일이 새로 만들어지다 중단되면 `recover`가 멈출 수 있습니다. 이때는 README의 수동 절차(pending 폴더 옮기기)를 따릅니다.
- 건너뛰거나 취소한 미리보기의 staging 폴더(내려받은 평문 사본)는 자동으로 지우지 않습니다. 필요 없으면 사용자가 지웁니다.
- 2차 감사 중 실제 DB를 읽기 전용으로 읽다가 SQLite `disk I/O error`가 한 번 났고 재시도에서는 정상이었습니다. 목록이 실패하면 다시 불러오면 됩니다.
- 실행 파일(`Run-CtxHop-GUI-vNext.cmd`)과 설치 파일의 바로가기는 `-ExecutionPolicy RemoteSigned`를 씁니다. 폴더 선택 수정 뒤의 시험 6개는 이 설정으로 통과했습니다. 브라우저로 받은 zip을 그대로 풀면 인터넷 출처 표시 때문에 실행이 막힐 수 있습니다(zip 속성에서 차단 해제 후 풀기). 설치 파일로 설치한 파일에는 이 표시가 붙지 않습니다.
- `gui-*-preview.png` 스크린샷에는 이 PC 이름과 사용자 경로가 보입니다.
- Python은 260자를 넘는 경로를 읽지 못합니다(Windows 긴 경로 설정이 꺼진 경우). 아주 긴 데이터 폴더 경로에서는 가져오기가 실패하고 복구가 필요할 수 있습니다.
