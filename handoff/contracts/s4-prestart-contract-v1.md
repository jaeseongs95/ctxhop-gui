# S4 protected engine 계약 v1 — R45 구현 기준

상태: 로컬 구현·fixture 수용 기준. R44 제안의 필요한 부분을 구체화하며, 구현 또는 감사 PASS를 발급하지 않는다. 사용자 2026-09-30 ‘주도해서 완성’ 요청으로 로컬 구현·검증을 재개한다. 실데이터·설치 앱·전역 설정·push·PR 변경은 금지한다. S3 자동 되돌리기 약속을 유지하며 대화 자동 삭제는 하지 않는다.

## 제공자와 신뢰

새 protected engine은 Codex의 실제 loader/typed Config/auth/cloud 선택을 재사용하는 로컬 수정 build다. 일반 CLI를 사후 조회하는 shim은 인정하지 않는다. standalone entry를 우선해 CLI arg0/install/logger의 선행 쓰기를 피한다. 일반 app-server API transport에 이어지는 방식은 기존 crate와 런타임을 재사용한다. 실행파일 이름은 `ctxhop-codex-engine.exe`로 제안하되 빌드 지점은 엔진 담당자가 가장 작은 안전 경로로 결정한다.

Go는 실행 전 배포에 결속된 engine 파일 hash와 contract major를 검사한다. caller가 출력 JSON을 위조하거나 arbitrary engine의 자기 선언을 근거로 신뢰하지 않는다. 최종 build hash는 소스·patch·검증 근거·별도 감사에 결속한다. 현재 정상 target engine과 protected engine의 loader 의미가 대응한다는 근거가 없으면 실제 홈의 안전한 지원 완료로 표시하지 않는다. source/binary 대응은 최종 수용 필수 조건이다.

## transport

익명 stdin/stdout pipe의 한 줄 JSON-RPC를 사용한다. prestart frame은 `{"id":1,"method":"ctxhop/prepare","params":{...}}`, 응답은 `{"id":1,"result":{...}}` 또는 `{"id":1,"error":{"code":-32000,"message":"safe explanation","data":{"reasonCode":"..."}}}`다. ID는 양의 정수다. 비밀과 config 원문은 stdout/stderr/error/receipt에 내보내지 않는다. 별도 socket/listener를 만들지 않는다.

각 요청을 한 번 보내고 응답을 받은 뒤 다음 요청을 보낸다. 제한·타임아웃·EOF·취소를 지키며, unknown frame/schema는 진행하지 않는다. `activate` 응답 뒤에는 기존 stable app-server `initialize`를 호출한다. 앱서버의 experimental capabilities는 비운다. stable API 서버 요청은 실패로 처리한다. prestart listener가 activation 뒤 원본 stdio bytes를 잃지 않는 연결은 담당자가 직접 검증한다.

## prepare

요청의 필수 필드:

```json
{
  "contractVersion": 1,
  "requestNonce": "32 lower-case hex",
  "operation": "plan|import|reference|cold|bootstrap|rollback|rollback-check",
  "home": "absolute path",
  "cwd": "absolute path",
  "offline": true,
  "members": [
    {"id":"uuid","parentId":null,"role":"root|child","rolloutPath":"absolute staged/current file or null","rolloutSha256":"hex or null"}
  ]
}
```

plan의 archive/support 검사는 Go가 하며 `members`를 비워도 된다. 이 경우 resume context는 승인되지 않았다. import/reference/cold/rollback은 엔진이 실제 rollout의 history/settings/metadata와 v2 부모 context를 검증해야 한다. 정확한 bytes를 pipe로 전달하는 대안은 wire 변경을 합의하고, plan을 위해 임시 rollout을 쓰지 않는다.

기본 `offline=true`는 네트워크 요청0이다. 유효한 기존 인증/cache로 resolve 가능한 경로를 정상 정책 의미로 지원한다. PAT/WIF/등록/refresh/expired cache 등 추가 효과가 필요하면 구체적 이유로 차단하며 무인증·unmanaged로 바꾸지 않는다. 온라인 정책 조회/인증 유지 경로는 정상 의미·효과·권한·취소 조건을 구현·검증하기 전 성공 기능으로 표시하지 않는다. 실제 외부 API·실제 credential을 시험에 쓰지 않는다.

응답은 엔진이 내부에 보유한 객체의 제한 projection이다. 필수:

```json
{
  "contractVersion": 1,
  "requestNonce": "echo",
  "processId": 123,
  "processNonce": "opaque per process",
  "snapshotId": "opaque per process",
  "generation": 1,
  "engineVersion": "numeric source version",
  "loaderContractId": "source/build-bound identifier",
  "inputComplete": true,
  "home": "resolved home",
  "normalSqliteHome": "canonical root",
  "operationSqliteHome": "canonical root",
  "stateDb": "canonical state_5.sqlite",
  "sqliteRedirect": false,
  "writeTargets": [],
  "projectConfig": [],
  "contexts": [],
  "authResolution": "resolved",
  "policyResolution": "resolved",
  "validity": {"kind":"normal-loader-semantics","revision":"opaque","expiresAt":null},
  "projectionDigest": "sha256 of safe projection",
  "acquisitionId": null,
  "effects": {"applicationWrites":0,"networkRequests":0,"sqliteShmMayChange":false,"privateSqliteSidecarsMayChange":false}
}
```

`writeTargets`는 실제 SqliteConfig descriptor를 사용한 `{kind,path}` 배열이며 kind는 `state|logs|goals|memories|memoriesV2|queue|threadHistory`다. `contexts`는 `{memberId,ownerId,phase,cwd,rolloutSha256,settingsDigest,contextId,sqliteHome}` 배열이며 phase는 `startup|firstResume|coldResume|reference|rollbackAbsent`다. startup의 memberId/ownerId/rolloutSha256/settingsDigest는 null일 수 있다. rollbackAbsent는 아래 부재 증명 조건에서만 rolloutSha256/settingsDigest가 null이다. settingsDigest는 비밀을 제외한 permission/cwd 설정 projection에만 적용하며 전체 Config/auth digest는 내부에 둔다. `projectConfig`는 `{path,applied,warning}` 배열이다. 알 수 없는 값/순서/효과를 빈 배열로 속여 통과시키지 않는다. source 후보 존재·부재/semantic root sqlite marker와 project warning은 실제 loader에서 계산한다. source full settings와 secret-bearing digest는 엔진 내부에서만 binding한다.

`CODEX_SQLITE_HOME` 존재와 검사 대상 TOML root `sqlite_home` 존재는 값이 H여도 거절한다. N/R mismatch·H 밖 DB·input unknown·auth/policy error도 거절한다. 데이터 DB는 최초 prepare에서 열지 않는다. auth keyring key 자동 생성·저장·delete·refresh persistence, cache 저장·background task, rollout/log/marker/migration/plugin/MCP 효과는 준비/accept 동안0이다. `inputComplete=true`는 검증이 구현된 source에 한해서만 반환한다.

기존 cold/rollback의 canonical resume는 DB 메타데이터도 입력으로 사용하므로 `ctxhop/complete`로 준비를 마친다. 최초 prepare는 startup의 실제 객체와 N/R/H·쓰기 대상을 확정하고 `inputComplete=false`를 반환한다. plan/bootstrap의 startup-only projection은 acquisitionId=null이며 member context 승인은 아니다.

### 동일 세대 acquisition — R45 연결 계약

원본 DB를 SQLite로 열지 않는다. Go는 정확한 자기 prepared process를 Job/image/incarnation/channel에 결속한 guard 뒤, 원본 디렉터리·ancestor·main·존재 WAL·존재 SHM의 raw 핸들을 획득한다. 파일은 READ/share-READ이며 directory metadata 핸들은 DELETE 공유를 금지한다. 모든 source 핸들 획득 뒤에만 bytes를 읽는다. source reparse/hardlink/path-identity 불일치, rollback journal 존재, 부재 WAL/SHM의 새 등장, 기존 쓰기 핸들/mapping 공유 충돌, 크기/복사/ACL/close 오류는 차단한다. 부재 이름 전체의 절대 잠금을 주장하지 않는다.

Go는 source 밖의 매번 새 private directory를 현재 사용자 SID owner·protected single-SID DACL로 만든다. 첫 byte 전에 ACL/identity를 확인하고 CREATE_NEW로 main과 존재 WAL만 복사한다. source SHM은 복사하지 않는다. 한 acquisition의 finalized 사본을 Go U-a와 Rust canonical metadata 양쪽이 읽으며 별도의 두 사본은 허용하지 않는다. original Config/home/stateDb/writeTargets와 source 의미는 바뀌지 않는다. private path는 acquisition 조회 인자일 뿐 runtime SqliteConfig가 아니다.

complete params의 기존 binding에 다음 `dbObservation`을 더한다. 필드는 정확히 아래와 같으며 unknown/duplicate/잘못된 타입은 거절한다.

```json
{
  "stateDb": "actual canonical source state_5.sqlite",
  "mainSha256": "64 lower-case hex",
  "walSha256": null,
  "acquisition": {
    "schemaVersion": 1,
    "acquisitionId": "32 lower-case hex",
    "source": {
      "directoryIdentity": "24 lower-case hex",
      "main": {"identity":"24 lower-case hex","size":4096,"sha256":"64 lower-case hex"},
      "wal": null,
      "shm": null
    },
    "private": {
      "directory": "absolute newly owned private directory",
      "directoryIdentity": "24 lower-case hex",
      "main": {"identity":"24 lower-case hex","size":4096,"sha256":"same main sha256"},
      "wal": null
    },
    "rollbackJournalAbsent": true
  }
}
```

wal/shm의 null은 직접 관측한 부재다. 존재하면 main과 같은 `{identity,size,sha256}` 객체다. private.wal은 acquisition 전에 복사한 source.wal의 존재/size/hash와 일치한다. Windows identity는 `GetFileInformationByHandle`의 VolumeSerialNumber/FileIndexHigh/FileIndexLow를 순서대로 각각 8자리 소문자 hex로 이어 붙인 `win32-file-index-v1` 표현이다. source와 private directory/main/존재 WAL identity는 달라야 한다. 각 main/WAL 상한 및 합계 상한은 Go의 기존 limit(1 GiB) 이하다. source SHM은 기존 bounded sidecar 상한을 적용한다. provider는 원본 실제 descriptor, directory/file handle identity, 최종 경로, source/private 존재 상태와 digest, private single-SID ACL/owner를 조회 전에 검증한다. caller가 제공한 문자열만으로 인정하지 않는다.

Go U-a는 private SQLite의 read-only open/query만 한다. Rust는 동일 private DB를 한 read-only pool(create_if_missing=false/query_only)에서 모든 member에 대해 공유 canonical SQL/ThreadRow decoder로 읽고 성공/오류 모두 pool.close를 await한다. source/config/auth를 private DB로 바꾸지 않는다. migration/init/repair는 양쪽 acquisition 조회에서 금지한다. provider가 private reader를 완전히 닫은 뒤 source/private 검증을 마치고 최종 generation을 올리며 acquisitionId를 projection에 결속한다.

private SQLite는 private SHM을 생성/갱신할 수 있고, source WAL이 없었으면 private의 빈 WAL 파일을 생성할 수 있다. source null을 private sidecar 존재로 바꾸지 않는다. private main과 복사된 기존 WAL의 identity/size/digest는 변하지 않아야 하며, 새 WAL은 길이0만 허용한다. 생성 sidecar는 bounded/owned/known identity로 등록해 정리한다. applicationWrites는 **원본 application namespace**에 대한 효과이며 private acquisition byte copy/SQLite sidecar 효과를 포함하지 않는다. projection은 original sqliteShmMayChange=false, completed acquisition의 privateSqliteSidecarsMayChange=true로 허용 범위를 명시한다. 이 자체 선언은 OS/backend 효과 검증을 대신하지 않는다.

Go는 최종 source 재검증 → 모든 private reader 종료 확인 → private owned identity 정리 → source 핸들 해제 → fresh guard와 binding/config/auth/rollout/source identity·존재·size·digest 재검증 → accept/activate 순서로 진행한다. cleanup/close 실패를 성공으로 숨기지 않으며 해당 단계에서 차단한다. source handles 해제부터 canonical 첫 쓰기까지, 마지막 검증 직후를 포함한 경쟁 구간이 남는다. 기존 운영 조건인 정상 앱/CLI/IDE와 writer 닫힘을 유지하며 모든 미래 writer의 원자적 배타 lease를 증명했다고 표시하지 않는다. 실제 handoff 실패는 placing 전 차단, placing 이후 pending이다.

plan/bootstrap에서 acquisition을 쓰지 않은 경우 acquisitionId=null, privateSqliteSidecarsMayChange=false다. 다른 member operation은 acquisition 없는 complete를 거절한다. private scope permission/cleanup/provenance·same-generation decoder·Windows/backend 효과가 실제 검증되기 전에는 정상 missing-WAL의 지원 완료로 표시하지 않는다.

## accept / activate / abort

`ctxhop/accept` params는 `requestNonce,processNonce,snapshotId,generation,projectionDigest,operation`이다. 응답은 같은 binding과 `accepted:true`다. 무쓰기 상태를 유지한다. replay·잘못된 process/context·무효 입력·권위가 없는 정책·만료는 오류다. caller의 accept는 기존 요청 범위의 내부 수용 검증이며 별도 사용자 권한을 만들지 않는다.

`ctxhop/activate`는 같은 binding을 받는다. 동일 Config/AuthManager/정책·captured input 객체를 기존 runtime 초기화에 소비해야 하며 bootstrap·live getter·ConfigBuilder source를 다시 읽어 바꾸지 않는다. 초기화 직전 validity 검사 후 DB gate를 연다. 응답은 `activated:true`와 같은 binding이다. ACK 전 일부 초기화 쓰기가 생길 수 있으므로 통신 실패를 writes0으로 표현하지 않는다. ambiguous activation은 재전송하지 않고 소유 Job 정리·actual journal 상태로 처리한다.

`ctxhop/abort` 또는 activate 전 EOF는 금지 application effect0으로 종료한다. activate 뒤에는 기존 app-server stdin 종료·소유 Job active0 규칙을 사용한다.

activation 뒤 RPC는 initialize/initialized, thread/list, thread/read, thread/resume, thread/turns/list, thread/items/list, thread/attachment/list, thread/name/set, thread/archive, thread/delete 중 해당 operation과 승인 member에 필요한 것만 허용한다. thread/list는 useStateDbOnly=true를 필수로 보내 rollout scan/repair를 금지하며 member 제한 밖 자료를 변경하지 않는다. thread/start·turn/start·config/account/auth/tool 변경과 미승인 member/cwd는 거절한다. 서버 요청을 Go가 수용하지 않는다. 정상 standalone app-server가 이 제한을 우회해 설정을 재로드하지 못해야 한다.

## context와 정상 정책 의미

rollback/rollback-check에서 파일·DB 행·해당 ID에 닿는 연결·다른 저장소의 참조가 모두 없다고 fresh guard/U-a와 engine canonical readonly 검사로 확인한 member는 rollbackAbsent marker로 결속한다. 이는 실제 Config를 대신하는 기본값이 아니며 resume/name/archive 권한을 주지 않는다. 없는 member에는 delete를 보내지 않고 마지막 API·파일·DB 부재 검사 후 기록 정리만 한다. 파일은 없지만 DB 행이 남거나 부재를 증명하지 못하면 needs_attention이며 이 예외로 삭제하지 않는다. memberId/ownerId는 해당 ID로 결속하고 cwd/sqliteHome는 승인된 startup 대상이다. marker는 snapshot/context ID와 부재 관측을 내부에서 보유해 activate 전 변화/replay를 거절한다.

첫 resume는 `approvalPolicy=untrusted`, `approvalsReviewer=user`, `sandbox=read-only`, 목표 cwd, excludeTurns=true다. cold resume는 요청값 없는 원 계약을 유지한다. v2 child는 활성 부모의 실제 승인된 설정을 따른다. 엔진 내 모든 load_for_cwd/session-layer/refresh 경로가 준비 context 소비를 우회하지 못해야 한다. 미승인 context·새 source/auth/policy revision은 새 준비·검증 전 쓰기를 시작하지 않는다.

freshness와 철회는 정상 vendor loader의 문서화된 의미를 유지한다. 서버가 발급하지 않은 즉시 철회 lease/임의 TTL을 발명하지 않는다. 관측한 제한이 새 설정을 요구하면 신규 작업 admission을 막고 안전한 drain 경계대로 중단한다. freeze만으로 모든 원격 철회의 즉시 준수를 보장했다고 표시하지 않는다. bootstrap/final auth route 불안정은 실패이며 기본값/무인증 fallback이 아니다.

## S4 순서·실패

외부 guard → startup safe prepare → 정확한 자기 prepared PID만 식별하는 guard → 같은 private acquisition의 U-a 읽기 → ctxhop/complete의 단일 readonly pool metadata/context 확정 → 최종 projection/source 검증 → reader·private 정리와 source handle 해제 → fresh guard/입력/source 검증 → accept/activate → A의 같은 ID/file 부재 확인 → 파일 배치 → 첫 resume → Job 종료 → cold/reference 검증 → 보관 마지막 → 정리/complete.

guard의 자기 PID 판정은 Job·image·incarnation·channel·prepared 상태를 결속해야 한다. final guard는 Job active0 뒤다. 기존 DB 부재는 unknown, 새 홈 bootstrap은 기존 R43-S-2만 예외다. 원본 DB 본문/WAL/SHM 무변경, private sidecar 한정 효과, 외부 연결/구조 불명 중단을 유지한다. `placing` 이상 실패는 자동 대화 삭제 없이 pending이며 UI가 수동 recover를 제공한다. rollback은 fresh prepare+U-a와 prefix/settings/foreign refs/attachments/DB를 확인한 뒤 명시적 사용자 recover에서만 engine delete를 한다.

## 실제 수용 근거

합성 fixture의 prepare/abort/EOF/keyring 오류/cache/identity/auth-maintenance/redirect/config malformed 효과0, capture 후 변경·replay·context/metadata/V2·activation 같은 객체, 모든 DB init/repair/migrate/backfill gate, nested Job, phase/journal/rollback 장애, 실제 legacy full turns/v2/archived 비교가 필요하다. 보고서의 자체 `effects=0`만으로 수용하지 않는다. 원 syscall/backend 호출·프로세스/network·파일 관측과 source 경로를 대조하고 고정 후보를 별도 감사한다.
