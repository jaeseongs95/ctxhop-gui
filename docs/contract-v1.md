# 벤더 계약 v1

Worker(`Worker.ps1`)가 벤더 구현을 부르는 방법입니다. 벤더를 더하려면 이 계약을 따르는 구현 하나와 `impls.json` 한 줄을 더합니다. Worker와 GUI는 바꾸지 않습니다.

| 벤더 | 구현 | 대화 저장·전송 |
|---|---|---|
| `codex-desktop` | `CodexDesktop.ps1` | 고정한 Python 백엔드(`backend\desktop_sessions.py`)가 목록·백업과 기존 ID 경로를 맡습니다. 새 ID 복원은 Go 구현(`bin\ctxhop-codex.exe`)과 보호 엔진을 사용합니다. 전송은 공통 도구 `bin\ctxhop.exe bundle`입니다. |
| `claude-code` | `ClaudeCode.ps1` | `ClaudeWorker.ps1`의 대화 작업을 그대로 감쌉니다. 전송은 `bin\ctxhop-claude.exe push/resume`입니다. |

S4의 새 ID 복원 경로와 실행 파일 결합은 [`s4-prestart.md`](s4-prestart.md)에 설명합니다. 미리보기의 영수증은 Go/Python 경로를 고정하며, Go 오류나 차단을 Python 복원으로 우회하지 않습니다. 개발 중인 실제 엔진 검증 상태도 그 문서와 검증 기록에서 구분합니다.

## 1. 역할

- **구현이 맡는 것**: 대화 목록, 작업 폴더 알리기, 대화 백업과 전송, 미리보기, 복원, 열기, 그 벤더의 복구 기록.
  - 대화 파일 형식과 저장 위치는 구현 안에만 있습니다. Worker는 해석하지 않습니다.
  - `remoteId`, `receipt`, `token`, `view`, `detail`은 구현이 만든 불투명한 값입니다. Worker는 저장하거나 해석하지 않고, 받은 그대로 다음 요청이나 GUI에 넘깁니다.
- **Worker가 맡는 것**:
  - 작업 잠금(한 번에 한 작업)
  - 프로젝트 파일(작업 폴더 백업·비교·복원). 벤더와 상관없이 같은 방식입니다.
  - 벤더 선택. 목록 행의 `agent`는 구현이 아니라 Worker가 붙입니다.
  - 사용자에게 묻기(큰 폴더). 구현은 UI를 띄우지 않습니다.
  - 설정·저장소 작업(설정, 상태, 저장소 옮기기, 프로젝트 등록 등). 벤더와 무관한 ctxhop 설정 작업이라 계약에 넣지 않습니다.
- **식별**:
  - 이 PC의 대화는 `(벤더, nativeId)`로 구별합니다.
  - 공유 백업은 `(벤더, remoteId)`로 구별하되, 목록을 불러온 한 흐름 안에서만 씁니다.
  - 다른 벤더의 같은 UUID는 다른 대화입니다. 프로젝트 파일 기록도 벤더 이름을 묶어 두고, 다른 벤더의 기록은 받지 않습니다.

## 2. 호출

- **실행**: `impls.json`에서 벤더 이름에 해당하는 명령 배열 뒤에 `<op> --request <파일> --response <파일>`을 붙여 실행합니다.
  - 실행 파일은 PATH에서 찾지 않습니다. `powershell.exe`는 System32의 것을, 그 밖의 이름은 `impls.json` 폴더를 기준으로 찾습니다.
  - 작업 폴더는 앱 폴더입니다. 구현은 Worker의 콘솔을 물려받습니다(ctxhop 암호 입력, 대화 열기).
- **파일**:
  - 호출마다 `%LOCALAPPDATA%\CtxHopGUI\jobs\<op>-<requestId>` 폴더를 새로 만듭니다.
  - 요청·응답은 UTF-8 JSON이고, 각각 16 MiB 이하입니다.
  - 구현은 응답을 `<응답>.tmp`에 쓴 뒤 이름을 바꿉니다.
  - Worker는 응답을 읽은 뒤 `request.json`, `response.json`, `response.json.tmp`를 지우고 빈 폴더를 지웁니다. 구현이 다른 파일을 남기면 그 폴더는 남습니다.
- **종료 코드**:
  - `0`: 응답을 썼습니다. 결과는 `status`로 봅니다.
  - `2`: 요청을 읽지 못했거나 잘못된 요청이라 아무것도 하지 않았습니다. 응답은 없습니다.
    - 잘못된 요청의 예: 인수 형식, 16 MiB 초과, `protocolVersion`이 정수 1이 아님, CLI의 op와 요청의 `op`가 다름, `requestId`가 GUID가 아님
  - 그 밖의 값: 구현이 비정상으로 끝났습니다.
- **시간 제한**:
  - `probe`·`guard` 120초, `list`·`describe` 1800초
  - `backup`, `preview`, `restore`, `open`, `recover`는 제한이 없습니다. 암호 입력이나 대화 창을 기다릴 수 있기 때문입니다. 백업과 미리보기는 GUI의 취소로 멈춥니다. 복원·열기는 GUI가 취소를 막습니다.
  - 시간이 넘으면 Worker는 구현 프로세스와 그 자식 프로세스를 부모-자식 관계로만 끝냅니다(`taskkill /T`). 이름으로 찾아 다른 프로세스를 끝내지 않습니다.
  - ponytail: 이미 부모가 끝나 떨어져 나간 손자 프로세스는 찾지 못합니다. 그 경우는 각 벤더의 쓰기 잠금과 복구 기록이 막습니다.
- **결과를 알 수 없는 경우**: 응답이 없거나, 검사에 실패하거나, 시간이 넘거나, 비정상으로 끝나면 Worker는 실패로 처리합니다.
  - 이때 구현이 어디까지 했는지는 모릅니다(`vendorOutcome=unknown`). 이미 올렸거나 썼을 수 있습니다.
  - Worker는 이 실패를 `busy`로 바꾸거나 자동으로 다시 시도하지 않습니다. 사용자에게 결과를 확인하라고 알립니다.
- **Worker 결과 파일**: 실패하면 GUI가 읽는 결과에 계약의 실패 정보를 남깁니다.
  - `vendor`: 구현이 답한 `status`, `reasonCode`, `recovery`
  - `vendorOutcome`: 응답이 없어 결과를 알 수 없으면 `unknown`
  - `backendResult`: 구현이 남긴 `detail`. 진행 중이면 `{status: busy}`입니다.

## 3. 요청과 응답

**요청 공통 필드**

| 필드 | 형식 | 뜻 |
|---|---|---|
| `protocolVersion` | 정수 `1` | |
| `requestId` | GUID 문자열 | |
| `op` | 문자열 | CLI의 op와 같아야 합니다. |
| `language` | `ko` \| `en` | 구현이 만드는 문장의 언어 |
| `home` | 문자열 | Codex 데이터 폴더. 빈 값이면 구현이 `CODEX_HOME`이나 기본 위치를 씁니다. |
| `projectPath` | 문자열 | GUI의 프로젝트 폴더(복원 대상, Claude 등록 폴더) |
| `identity` | 문자열 | Claude 프로젝트 등록 이름 |

- 요청에는 비밀정보를 넣지 않습니다.
- 구현은 Worker에서 물려받은 벤더 표준 환경변수(`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `CTXHOP_CONFIG_DIR`)를 읽을 수 있습니다.

**응답 공통 필드**

| 필드 | 형식 | 뜻 |
|---|---|---|
| `protocolVersion` | 정수 `1` | |
| `requestId`, `op` | 문자열 | 요청과 같아야 합니다(대소문자 구별). |
| `status` | 문자열 | op마다 허용된 값만 씁니다(아래 표). |
| `reasonCode` | 문자열 | 분기에 쓰는 고정 코드입니다. 없으면 빈 값입니다. |
| `reason` | 문자열 | 사람이 읽는 이유입니다(`language`로 작성). Worker는 이 문장으로 분기하지 않습니다. |
| `message` | 문자열, 선택 | 성공했을 때 보여 줄 문장 |
| `detail` | 객체, 선택 | 실패했을 때 구현이 남기는 진단 기록(예: 복구 기록 목록). GUI가 "복구 기록"으로 그대로 보여 줍니다. |
| `recovery` | `none` \| `required` \| `unknown`, 선택 | `restore`가 실패했을 때 대상에 쓰기가 남았는지 알려 줍니다. 실제로 되돌렸는지 확인하지 않았으면 되돌렸다고 적지 않습니다. |

- Worker는 `requestId`, `op`, `protocolVersion`, 허용된 `status`를 검사합니다. `status`가 `ok`이면 아래 필수 필드의 형식도 검사합니다.
- 모르는 필드는 허용하지만, 필수 필드의 형식이 틀리면 응답 전체를 받지 않습니다.
- 상한은 응답 전체 16 MiB 하나입니다. 목록은 나눠 보내지 않고, 넘으면 잘라 보내지 않습니다. 구현은 `failed`와 `reasonCode=response_too_large`로 알립니다. 필드별 상한은 두지 않습니다.

**status**

| op | 허용 status |
|---|---|
| `probe` | `ok`, `failed` |
| `list`, `open`, `recover` | `ok`, `unsupported`, `failed` |
| `describe` | `ok`, `busy`, `unsupported`, `failed` |
| `backup` | `ok`, `busy`, `changed`, `unsupported`, `failed` |
| `preview`, `restore` | `ok`, `unsupported`, `failed` |
| `guard` | `ok`, `busy`, `unsupported`, `failed` |

- `busy`는 진행 중인 대화라서 건너뛰었다는 뜻입니다. 실패가 아니며, GUI는 건너뜀으로 셉니다.
- `changed`는 `describe` 뒤에 작업 폴더가 바뀌어 아무것도 올리지 않았다는 뜻입니다(`reasonCode=source_changed`).
- `unsupported`는 그 구현이 하지 않는 op입니다. 구현이 처리하지 않는 op에는 공통 진입점이 `reasonCode=op_unsupported`로 답합니다.

## 4. op

| op | 요청(공통 외) | `ok` 응답의 필수 필드 |
|---|---|---|
| `probe` | 없음 | `capabilities`: 처리하는 op 이름 배열 |
| `list` | `search` | `sessions`: 행 배열. 선택 필드는 `excluded`(정수)와 `message`입니다. |
| `describe` | `nativeId` | `sourceCwd`(문자열), `cwds`·`edits`(문자열 배열), `sourceStamp`(문자열) |
| `backup` | `nativeId`, `remoteId`, `sourceStamp` | `remoteId`(빈 값 아님). 선택 필드는 `message`입니다. |
| `preview` | `nativeId`, `remoteId` | `state`(문자열), `choices`(배열, 값은 `incoming`만), `receipt`·`token`(문자열, 빈 값 가능). 선택 필드는 `view`와 `message`입니다. |
| `restore` | `nativeId`, `remoteId`, `receipt`, `token`, `choice`, `operationId` | `effect`(`restored` \| `equal` \| `local_newer`), `nativeId`. 선택 필드는 `view`와 `message`입니다. |
| `open` | `nativeId`, `remoteId` | 선택 필드 `message` |
| `guard` | 없음 | 없음. 대상 엔진·writer가 모두 닫혀 있을 때만 `ok`이고, 열려 있으면 `busy`(`reasonCode=engine_open`)입니다. 읽기만 합니다. |
| `recover` | `mode`와 모드별 값(아래) | 모드별(아래) |

**목록 행 (`list.sessions[]`)**

| 필드 | 필수 | 형식과 뜻 |
|---|---|---|
| `nativeId` | 예 | GUID 문자열. 확인하지 못한 공유 백업이면 빈 값이고, 이때는 `blockedReason`이 필요합니다. |
| `remoteId` | 예 | 문자열. 빈 값은 공유 백업이 없다는 뜻입니다. |
| `title` | 예 | 문자열 |
| `local` | 예 | bool. 이 PC의 대화인지 |
| `recordCount` | 예 | 0 이상의 정수 |
| `blockedReason` | 아니요 | 문자열 또는 null. 값이 있으면 그 행은 선택할 수 없습니다. |
| `updatedAt` | 아니요 | RFC 3339 문자열 |
| `sourceCwd` | 아니요 | 문자열. 없거나 빈 값은 원래 폴더를 모른다는 뜻입니다. |
| `archived` | 아니요 | bool |
| `children` | 아니요 | 하위 대화 수, 또는 null(모름) |

- 행 순서는 구현이 정하고, Worker는 그대로 둡니다.

**백업: 큰 폴더 확인과 스냅숏**

- Worker는 프로젝트 파일을 함께 올릴 때만 `describe`를 부릅니다. 받은 작업 폴더로 올릴 폴더를 정하고, 큰 폴더는 사용자에게 먼저 묻습니다.
- `sourceStamp`는 `sourceCwd`·`cwds`·`edits`의 SHA-256입니다(`Get-SourceStamp`). 구현은 `backup`에서 다시 계산합니다.
  - 값이 다르면 아무것도 올리지 않고 `changed`로 답합니다. 사용자가 확인하지 않은 새 폴더를 승인된 것으로 다루지 않기 위해서입니다.
  - `sourceStamp`가 빈 값이면 비교하지 않습니다(프로젝트 파일을 올리지 않을 때).
- `describe`는 사용자 기록을 바꾸지 않습니다. 임시 사본이 필요하면 staging에 만들고 응답하기 전에 지웁니다.
  - Codex는 `describe`와 `backup`이 각각 내보냅니다.
  - ponytail: 이 때문에 프로젝트 파일을 올릴 때 내보내기를 두 번 합니다. 느리면 `describe`의 사본을 receipt로 넘기는 방식으로 바꿉니다.
- 폴더 크기와 내용은 그 뒤에도 바뀔 수 있습니다. 그래서 Worker는 실제로 읽는 압축 전 총량을 제한합니다.
  - 허락받은 폴더는 받는 쪽 한도(16 GiB)까지 읽습니다.
  - 묻지 않은 폴더는 묻는 기준(200 MB)보다 작을 때까지만 읽습니다.
  - 내용 해시를 구할 때와 압축할 때 모두 셉니다.
  - 넘으면 그 폴더는 올리지 않고 이유를 남깁니다. 허락받지 않은 폴더는 "커졌는데 허락받지 않음", 허락받은 폴더는 `tooLarge`입니다.
  - 같은 내용의 백업이 이미 있으면 올리지 않고 연결만 합니다.
- 대화 백업이 끝난 뒤 프로젝트 파일이 실패해도 대화 백업(`remoteId`)은 그대로입니다. 결과에 따로 남고, 같은 대화를 다시 올리지 않습니다.

**미리보기·복원: receipt, token, choice**

- `choices`는 미리보기에서 허용한 선택입니다. 복원할 수 있으면 `["incoming"]`이고, 손상·호환 불가면 빈 배열입니다.
  - 건너뛰기·유지는 GUI가 작업을 만들지 않고 끝냅니다. 그래서 `restore`의 `choice`는 `incoming`뿐입니다.
- `restore`는 `choice`가 `choices` 안에 있는지, `receipt`와 `token`이 미리보기 때와 같은지 구현이 확인합니다.
  - Codex: `receipt`는 구현의 staging 안 `inspect.json`만 받습니다. 받은 archive 해시, `remoteId`, `nativeId`, 대상 홈, 대상 폴더, token이 모두 같아야 합니다.
  - Claude: `receipt`는 빈 값입니다. 대화는 복원 직전에 미리보기를 다시 검사합니다. `token`은 미리보기마다 새로 만드는 일회용 값이고, 아래 짝 확인에만 씁니다.
  - GUI는 두 벤더 모두 미리보기가 준 `receipt`와 `token`을 복원 요청에 그대로 돌려줍니다.
- **대화 미리보기와 프로젝트 미리보기의 짝**:
  - Worker는 프로젝트 미리보기 기록(`project-receipt.json`)에 같은 미리보기의 값을 함께 적습니다.
    - 벤더, `nativeId`, `remoteId`
    - 대상 홈, 복원 폴더
    - 벤더 `receipt`, `token`
  - 복원할 때 이 값이 요청과 모두 같아야 합니다. Worker는 벤더 `restore`를 부르기 전에 확인합니다.
  - 하나라도 다르면 대화도 파일도 쓰지 않고, 어느 미리보기 사본도 지우지 않고 멈춥니다. 다른 벤더의 같은 UUID나, 같은 대화의 다른 미리보기를 섞는 경우가 여기서 막힙니다.
  - 미리보기 뒤에 고르는 폴더는 이 PC에 원래 경로가 없던 추가 폴더(`needsFolder`)에만 씁니다. 절대 경로여야 합니다. 시작 폴더는 늘 복원 폴더이고, 원래 경로가 있는 추가 폴더는 그 경로를 씁니다.
- **순서**: Worker는 프로젝트 파일을 먼저 쓰고 대화는 맨 마지막에 복원합니다.
  - 미리보기 `state`가 `local_newer`이면 `restore`가 대화에 쓰지 않는다는 뜻입니다. Worker는 이때 프로젝트 파일을 쓰지 않습니다. Worker는 이 값을 프로젝트 미리보기 기록에 함께 적어 둡니다.
  - 프로젝트 파일을 처음 쓰기 전에 `guard`를 부릅니다. `ok`가 아니면 아무것도 쓰지 않습니다.
  - 프로젝트 파일 하나라도 쓰지 못하면 `restore`를 부르지 않고, 쓴 파일을 되돌립니다.
- `effect`는 대화에 실제로 한 일입니다. `restored`·`equal`이면 복원이 끝납니다. `local_newer`이거나 실패해서 대화에 쓰지 않았으면 Worker가 방금 쓴 프로젝트 파일을 되돌립니다.
  - 복원 결과는 대화 결과(`effect`, `restored`)와 프로젝트 결과(`project`, 복구 위치)를 따로 둡니다. 판단은 아래 복구 기록 상태로 합니다.
- **수명과 정리**:
  - 미리보기 사본은 구현의 staging(`%LOCALAPPDATA%\CtxHopGUI\staging\<id>`)에 있습니다. 호출 폴더와 따로 있어서, 호출 폴더를 지워도 사라지지 않습니다.
  - 복원에 성공하면 구현이 대화 사본을 지우고, Worker가 프로젝트 사본을 지웁니다.
  - 실패하면 증거로 남습니다. 건너뛴 미리보기도 남습니다.

**복구 기록 (S3)**

- `operationId`는 Worker가 복원마다 만드는 32자 소문자 hex입니다. 구현은 **첫 쓰기 전에** 이 이름으로 복구 기록을 만듭니다.
  - Codex: 백엔드 `apply --run <operationId>`의 run 폴더(`<home>\.ctxhop-desktop-recovery\<operationId>`)
  - Claude: `%LOCALAPPDATA%\CtxHopGUI\recovery\<operationId>.pending.json`. 쓰기 전 상태(`prepared`)를 함께 적습니다.
  - 이름이 틀리거나 같은 이름의 기록이 있으면 아무것도 쓰지 않고 실패합니다.
- `recover`의 모드

| `mode` | 요청 | `ok` 응답 |
|---|---|---|
| `status` | `operationId` | `state`: `absent` \| `pending` \| `complete` \| `rolled_back` \| `resolved` \| `unreadable` |
| `list` | 공통 문맥 | `records`: 되돌리거나 닫아야 할 기록(`pending`·`unreadable`). 예전 형식 포함 |
| `rollback` | `recordId`, `confirmedUnknown`(선택, `{target, current}` 배열) | `effect: rolled_back`. 모두 원래대로일 때만 |
| `resolve` | `recordId`, `sha256` | `effect: resolved`. 기록 파일의 SHA-256이 사용자가 본 값과 같을 때만 이름을 바꿉니다. 이미 닫혔으면 성공입니다. |

- `records` 행: `recordId`, `operationId`(모르면 null), `nativeId`, `path`, `state`, `sha256`(기록 파일), `canRollback`, `files`(파일별 분류, 알 수 있을 때)
- 실패 응답은 `failed`와 `reasonCode`(`needs_attention` \| `unsupported_record` \| `changed` \| `busy`)를 함께 돌려주고, 남은 항목은 `records`에 담습니다. 모르는 `mode`는 기록을 읽기 전에 `failed`입니다.
- Claude 파일은 "이 작업이 씀"으로 인증하지 않습니다. 그래서 Claude `rollback`은 사용자가 확인한 알 수 없는 파일(`confirmedUnknown`)만 되돌리고, 치운 파일은 모두 `<operationId>.rollback\`에 남깁니다.
- `recover`를 부르는 것은 Worker뿐입니다. 구현 CLI를 직접 부르는 사용은 지원하지 않습니다.
- Worker는 복원마다 공통 표지(`%LOCALAPPDATA%\CtxHopGUI\journal\<operationId>.json`)를 남기고, 결정표로 마무리한 뒤 종료 기록(`journal\done\`)을 쓰고 표지를 지웁니다.
  - 미해결 표지·기록이 있거나 조회가 실패하면 복원·백업·열기를 모두 막습니다. 목록·미리보기와 `Journal`·`Rollback`·`CloseJournal` 작업은 막지 않습니다.
  - 벤더의 기존 보호도 그대로입니다. Codex 백엔드는 남은 `pending`이 있으면 쓰기를 막고, `ClaudeWorker`는 남은 `*.pending.json`이 있으면 백업·복원을 막습니다.
- 사용자가 모르게 실데이터를 되돌리는 호출은 두지 않습니다. 자동으로 되돌리는 것은 같은 복원 작업 안에서 방금 쓴 프로젝트 파일뿐입니다.

## 5. 시험

- `Test-Contract.ps1`:
  - 가짜 구현 프로세스로 클라이언트를 확인합니다. 사례는 잘린 JSON, 판·ID·op·status·필드 형식, 종료 코드, 시간 초과, 16 MiB, 한글·따옴표입니다.
  - 실제 구현의 진입점은 네이티브 도구를 부르기 전에 끝나는 요청(probe, 모르는 `recover` 모드, Codex 열기, 잘못된 요청)으로 확인합니다.
- `Test-DesktopWorker.ps1`, `Test-DesktopIntegration.ps1`:
  - 두 구현의 처리기를 같은 프로세스에서 부릅니다. 요청·응답은 JSON을 거치고 Worker와 같은 응답 검사를 받습니다.
  - 네이티브 호출은 시험 안에서 함수를 바꿔 흉내 냅니다.
  - 배포되는 구현은 시험용 mock을 읽는 경로(환경변수 등)를 두지 않습니다.
