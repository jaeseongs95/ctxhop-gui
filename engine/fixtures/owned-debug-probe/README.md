# owned synthetic debug lifecycle fixture

현재 단계는 source/archive build 준비다. 실제 probe 실행은 별도 검토 대상이다.

- Build-Probe.ps1은 PowerShell 7.4 이상과 caller가 지정한 설치 MSVC/SDK 경로·버전을 사용한다. 고정 Git archive의 LF source에서만 빌드하며 toolchain 스크립트의 공용 파일 쓰기나 설치를 수행하지 않는다.
- FixtureWorkspace는 caller가 지정하는 새 local absolute 경로이며 leaf는 ctxhop-owned-debug- 뒤 lowercase GUID 32자다. plain ancestors를 확인하고 owner/nonce를 build manifest에 고정한다. build-GUID/launch-GUID/run-GUID는 이 workspace 아래에만 생성하며 기존 workspace를 빌드에 재사용하지 않는다. workspace 경로는 Win32 fixture의 MAX_PATH 범위에 맞춰 180자 이하로 제한한다.
- Invoke-Probe.ps1의 Prepare는 승인 대상으로 지정한 build manifest와 source/images를 해시 검증하고 새 launch manifest만 만든다. run cwd/home/output과 observer는 만들거나 실행하지 않는다.
- Execute는 따로 검토한 launch manifest SHA256와 ExecuteReviewedProbe switch가 필요하다. 승인 해시 문자열은 자동 승인 장치가 아니며 실제 실행 권한은 호출자의 신뢰된 요청에서 받아야 한다.
- 외부 runner는 source/manifest/images를 FileShare.Read로 유지한다. observer도 image handles를 유지하고 CREATE 이벤트의 helper file ID를 대조한다. 부모와 자식은 같은 helper.exe의 고정 role이다.
- 정상 15초, cleanup 추가 5초, 이벤트 512개, raw 1MiB, receipt 64KiB, Job process 2개의 경계를 둔다. 기존 프로세스 attach, 메모리·symbol·debug string 읽기, API hook, broad PID kill, SQLite·engine·trace 실행은 없다.
- EXIT Continue 뒤 retained signal을 기록하고 자체 process references를 닫은 뒤 Job ActiveProcesses=0을 확인한다. 실제 호스트의 API 호환성, 초기 breakpoint와 Job accounting 동작은 runtime 실행 전에는 검증되지 않는다.
- 각 CREATE의 첫 Continue는 현재 slot/identity/Job membership 검증이 정상이거나, 현재 member에 대한 Job 종료 요청 또는 exact CREATE event hProcess의 종료 요청이 성공했을 때만 허용한다. 부모 bound 값을 자식 membership 대신 쓰지 않는다. slot2는 Job membership을 가정하지 않고 exact current handle 종료 요청만 사용할 수 있다. 모든 조건이 실패하면 Continue를 금지하고 debugger exit/kill-on-exit와 Job close를 요청하는 불완전한 receipt를 남긴다. 요청 성공은 EXIT Continue 뒤 retained signal 완료와 구별한다.
- continue-policy-test.c는 observer와 공유하는 순수 continue-policy.h의 slot0/1/2·validation·membership·termination return 조합 48개를 검사한다. 이 검사 프로그램은 Windows target/API를 실행하지 않으며 실제 observer/helper lifecycle의 성공 근거가 아니다.
- compiler는 정상 60초, observer wrapper는 정상 30초 이후 각각 최대 cleanup 5초와 output drain 5초의 deadline을 둔다. builder에 정의된 hash-pinned 함수 extent만 Invoke가 재사용한다. 무인자 WaitForExit나 완료되지 않은 async task의 GetResult에 의존하지 않으며 timeout/partial exit/drain 실패는 failure/unproven으로 보존한다. wrapper의 parent exit와 pipe drain은 전체 child Job 종료의 증거가 아니다.
- 성공 범위는 ownedSyntheticDebugLifecycle이다. 파일·네트워크 효과는 NOT_OBSERVABLE이며 제품 수용과 효과 부재를 증명하지 않는다.

빌드 manifest는 source commit/archive/inventory, 주요 compiler/linker/SDK/CRT 입력 해시, 실제 argv와 process-local 환경, stdout/stderr/exit code, 이미지 해시를 보존한다. 이는 설치 도구 전체의 완전한 공급망 증명이 아니다. 실패 출력과 namespace는 보존하며 자동 재시도·재사용·삭제를 하지 않는다.

nonce/hash/reparse 검사는 동일 사용자에게서 격리되는 ACL 또는 canonical ancestor directory lease가 아니다. 현재 후보는 동시 변경이 없는 trusted caller namespace를 전제로 하며 ancestor 교체 race 저항성을 증명하지 않는다. wrapper의 64KiB 출력 검사는 수집 뒤의 검사이며 streaming 메모리 hard cap이 아니다. OS/파일 API 자체의 wall-clock hard bound도 검증하지 않았다.
