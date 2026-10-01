# owned synthetic debug lifecycle fixture

현재 단계는 source/archive build 준비다. 실제 probe 실행은 별도 검토 대상이다.

- Build-Probe.ps1은 PowerShell 7과 이미 설치된 MSVC 14.44/SDK 10.0.26100.0을 사용한다. 고정 Git archive의 LF source에서만 빌드하며 toolchain 스크립트의 공용 파일 쓰기나 설치를 수행하지 않는다.
- Invoke-Probe.ps1의 Prepare는 승인 대상으로 지정한 build manifest와 source/images를 해시 검증하고 새 launch manifest만 만든다. run cwd/home/output과 observer는 만들거나 실행하지 않는다.
- Execute는 따로 검토한 launch manifest SHA256와 ExecuteReviewedProbe switch가 필요하다. 승인 해시 문자열은 자동 승인 장치가 아니며 실제 실행 권한은 호출자의 신뢰된 요청에서 받아야 한다.
- 외부 runner는 source/manifest/images를 FileShare.Read로 유지한다. observer도 image handles를 유지하고 CREATE 이벤트의 helper file ID를 대조한다. 부모와 자식은 같은 helper.exe의 고정 role이다.
- 정상 15초, cleanup 추가 5초, 이벤트 512개, raw 1MiB, receipt 64KiB, Job process 2개의 경계를 둔다. 기존 프로세스 attach, 메모리·symbol·debug string 읽기, API hook, broad PID kill, SQLite·engine·trace 실행은 없다.
- EXIT Continue 뒤 retained signal을 기록하고 자체 process references를 닫은 뒤 Job ActiveProcesses=0을 확인한다. 실제 호스트의 API 호환성, 초기 breakpoint와 Job accounting 동작은 runtime 실행 전에는 검증되지 않는다.
- 성공 범위는 ownedSyntheticDebugLifecycle이다. 파일·네트워크 효과는 NOT_OBSERVABLE이며 제품 수용과 효과 부재를 증명하지 않는다.

빌드 manifest는 source commit/archive/inventory, 주요 compiler/linker/SDK/CRT 입력 해시, 실제 argv와 process-local 환경, stdout/stderr/exit code, 이미지 해시를 보존한다. 이는 설치 도구 전체의 완전한 공급망 증명이 아니다. 실패 출력과 namespace는 보존하며 자동 재시도·재사용·삭제를 하지 않는다.
