#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>

#define NORMAL_EVENTS 448
#define MAX_EVENTS 512
#define NORMAL_BYTES 917504
#define MAX_BYTES 1048576
typedef struct {
    DWORD pid, threads, exitCode;
    ULONGLONG birth;
    HANDLE retained;
    BOOL member, breakpoint, exitContinued, signaled, referenceClosed;
} Life;
static volatile LONG cancelled;
static DWORD failure, failureError, cleanupError, events, continued, bytes;
static BOOL cleanup, incomplete, ledgerClosed = TRUE;
static HANDLE raw = INVALID_HANDLE_VALUE;

static BOOL WINAPI cancel_handler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT) {
        InterlockedExchange(&cancelled, 1); return TRUE;
    }
    return FALSE;
}
static void fail(DWORD reason, DWORD error) {
    if (!failure) { failure = reason; failureError = error; }
}
static void own_close(HANDLE *handle) {
    if (*handle && *handle != INVALID_HANDLE_VALUE) {
        if (!CloseHandle(*handle)) { ledgerClosed = FALSE; fail(30, GetLastError()); }
        *handle = NULL;
    }
}
static BOOL output(const char *text) {
    DWORD n = (DWORD)strlen(text), written = 0;
    if (n > 2048 || bytes > MAX_BYTES - n) {
        incomplete = TRUE; fail(31, 0); return FALSE;
    }
    if (!WriteFile(raw, text, n, &written, NULL) || written != n) {
        incomplete = TRUE; fail(32, GetLastError()); return FALSE;
    }
    bytes += n; return TRUE;
}
static BOOL same_file(const BY_HANDLE_FILE_INFORMATION *a,
                      const BY_HANDLE_FILE_INFORMATION *b) {
    return a->dwVolumeSerialNumber == b->dwVolumeSerialNumber
        && a->nFileIndexHigh == b->nFileIndexHigh && a->nFileIndexLow == b->nFileIndexLow;
}
static ULONGLONG birth_of(HANDLE process) {
    FILETIME birth, exit, kernel, user;
    ULARGE_INTEGER value;
    if (!GetProcessTimes(process, &birth, &exit, &kernel, &user)) {
        fail(33, GetLastError()); return 0;
    }
    value.LowPart = birth.dwLowDateTime; value.HighPart = birth.dwHighDateTime;
    return value.QuadPart;
}
static BOOL hex_arg(const wchar_t *text, size_t n) {
    return wcslen(text) == n && wcsspn(text, L"0123456789abcdef") == n;
}
static BOOL plain_path(const wchar_t *path) {
    DWORD attributes;
    wchar_t copy[MAX_PATH], *end;
    if (wcslen(path) >= MAX_PATH || path[1] != L':' || path[2] != L'\\'
        || wcschr(path, L'"') || wcsstr(path, L"..")) return FALSE;
    wcscpy_s(copy, MAX_PATH, path);
    for (end = copy + 3; ; ++end) {
        if (*end == L'\\' || *end == 0) {
            wchar_t saved = *end; *end = 0;
            attributes = GetFileAttributesW(copy);
            *end = saved;
            if (attributes == INVALID_FILE_ATTRIBUTES
                || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return FALSE;
            if (!saved) break;
        }
    }
    return TRUE;
}
static void sample_exit(Life *life) {
    DWORD wait;
    if (!life->retained || !life->exitContinued || life->signaled) return;
    wait = WaitForSingleObject(life->retained, 0);
    if (wait == WAIT_OBJECT_0) {
        DWORD code;
        life->signaled = TRUE;
        if (!GetExitCodeProcess(life->retained, &code) || code != life->exitCode)
            fail(34, GetLastError());
        own_close(&life->retained);
        life->referenceClosed = TRUE;
    } else if (wait == WAIT_FAILED) fail(35, GetLastError());
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *helper, *run, *root, *manifest, *helperSha, *observerSha;
    wchar_t rawPath[MAX_PATH], receiptPath[MAX_PATH], cwd[MAX_PATH], command[2*MAX_PATH];
    wchar_t selfPath[MAX_PATH], imagePath[MAX_PATH];
    wchar_t expectedRoot[MAX_PATH];
    LPWCH environment;
    char row[2048], receipt[8192], runA[33], manifestA[65], helperA[65], observerA[65];
    HANDLE job = NULL, helperPin = INVALID_HANDLE_VALUE, observerPin = INVALID_HANDLE_VALUE;
    HANDLE receiptHandle = INVALID_HANDLE_VALUE;
    BY_HANDLE_FILE_INFORMATION helperInfo = {0}, observerInfo = {0};
    PROCESS_INFORMATION process = {0};
    STARTUPINFOW startup = {0};
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION account = {0};
    Life life[2] = {{0}};
    DWORD osThread = GetCurrentThreadId(), active = 0xffffffff, total = 0, writeCount;
    DWORD imageLength, error, status, slot;
    ULONGLONG start, deadline, cleanupDeadline = 0, exitSequence[2] = {0};
    BOOL bound = FALSE, launched = FALSE, success = FALSE, killOnExit = FALSE;
    BOOL assigned = FALSE, ownParentClosed = FALSE;
    DEBUG_EVENT event;
    if (argc != 13 || wcscmp(argv[1], L"--helper") || wcscmp(argv[3], L"--run")
        || wcscmp(argv[5], L"--root") || wcscmp(argv[7], L"--manifest")
        || wcscmp(argv[9], L"--helper-sha") || wcscmp(argv[11], L"--observer-sha"))
        return 2;
    helper=argv[2]; run=argv[4]; root=argv[6]; manifest=argv[8];
    helperSha=argv[10]; observerSha=argv[12];
    if (!hex_arg(run,32) || !hex_arg(manifest,64) || !hex_arg(helperSha,64)
        || !hex_arg(observerSha,64) || !plain_path(helper) || !plain_path(root)
        || wcslen(root)>200)
        return 2;
    swprintf_s(expectedRoot,MAX_PATH,L"D:\\Go\\codex-s4\\helper3-r45-fixture-owned-debug-run-%ls",run);
    if (wcscmp(root,expectedRoot)) return 2;
    if (swprintf_s(rawPath,MAX_PATH,L"%ls\\out\\events.ndjson",root)<0
        || swprintf_s(receiptPath,MAX_PATH,L"%ls\\out\\receipt.json",root)<0
        || swprintf_s(cwd,MAX_PATH,L"%ls\\cwd",root)<0 || !plain_path(cwd)) return 2;
    {
        wchar_t out[MAX_PATH];
        swprintf_s(out,MAX_PATH,L"%ls\\out",root);
        if (!plain_path(out)) return 2;
    }
    raw=CreateFileW(rawPath,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if (raw==INVALID_HANDLE_VALUE) return 3;
    helperPin=CreateFileW(helper,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
    if (helperPin==INVALID_HANDLE_VALUE || !GetFileInformationByHandle(helperPin,&helperInfo))
        fail(4,GetLastError());
    if (!GetModuleFileNameW(NULL,selfPath,MAX_PATH) || !plain_path(selfPath)) fail(5,GetLastError());
    else {
        observerPin=CreateFileW(selfPath,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
        if (observerPin==INVALID_HANDLE_VALUE || !GetFileInformationByHandle(observerPin,&observerInfo))
            fail(5,GetLastError());
    }
    if (!SetConsoleCtrlHandler(cancel_handler,TRUE)) fail(6,GetLastError());
    job=CreateJobObjectW(NULL,NULL);
    if (!job) fail(7,GetLastError());
    limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE|JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit=2;
    if (job && !SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limits,sizeof(limits)))
        fail(8,GetLastError());
    start=GetTickCount64(); deadline=start+15000;
    startup.cb=sizeof(startup);
    swprintf_s(command,2*MAX_PATH,L"\"%ls\" --role parent --run %ls",helper,run);
    if (!failure) {
        environment=GetEnvironmentStringsW();
        if (!environment) fail(9,GetLastError());
        else launched=CreateProcessW(helper,command,NULL,NULL,FALSE,
            DEBUG_PROCESS|CREATE_UNICODE_ENVIRONMENT|CREATE_NO_WINDOW,
            environment,cwd,&startup,&process);
        if (environment) FreeEnvironmentStringsW(environment);
        if (!launched) fail(9,GetLastError());
        else {
            killOnExit=DebugSetProcessKillOnExit(TRUE);
            if (!killOnExit) fail(10,GetLastError());
        }
    }
    while (launched) {
        ULONGLONG now=GetTickCount64();
        DWORD waitTime;
        if (InterlockedCompareExchange(&cancelled,0,0)) fail(11,0);
        if (!cleanup && now>=deadline) fail(12,0);
        if (!cleanup && (events>=NORMAL_EVENTS || bytes>=NORMAL_BYTES)) fail(13,0);
        if (failure && !cleanup) {
            cleanup=TRUE; cleanupDeadline=now+5000;
            if (cleanupDeadline>start+20000) cleanupDeadline=start+20000;
            if (bound) {
                if (!TerminateJobObject(job,90)) cleanupError=GetLastError();
            } else if (process.hProcess) {
                /* Exact handle from this launch, before any permitted user-mode Continue. */
                if (!TerminateProcess(process.hProcess,90)) cleanupError=GetLastError();
            }
        }
        sample_exit(&life[0]); sample_exit(&life[1]);
        if (life[0].signaled && !ownParentClosed) {
            own_close(&process.hThread); own_close(&process.hProcess); ownParentClosed=TRUE;
        }
        if (life[0].signaled && (life[1].signaled || cleanup)) {
            if (!QueryInformationJobObject(job,JobObjectBasicAccountingInformation,&account,sizeof(account),NULL))
                fail(14,GetLastError());
            else { active=account.ActiveProcesses; total=account.TotalProcesses; }
            if (active==0) break;
        }
        now=GetTickCount64();
        if ((cleanup && now>=cleanupDeadline) || events>=MAX_EVENTS) {
            incomplete=TRUE; if (!failure) fail(15,0); break;
        }
        waitTime=(DWORD)((cleanup ? cleanupDeadline : deadline)-now);
        if (waitTime>250) waitTime=250;
        ZeroMemory(&event,sizeof(event));
        if (!WaitForDebugEvent(&event,waitTime)) {
            error=GetLastError();
            if (error!=ERROR_SEM_TIMEOUT && error!=ERROR_TIMEOUT) fail(16,error);
            continue;
        }
        ++events; status=DBG_CONTINUE;
        slot=event.dwProcessId==life[0].pid ? 0 : event.dwProcessId==life[1].pid ? 1 : 2;
        if (event.dwDebugEventCode==CREATE_PROCESS_DEBUG_EVENT) {
            BY_HANDLE_FILE_INFORMATION eventInfo;
            BOOL member=FALSE;
            slot=life[0].pid==0 ? 0 : life[1].pid==0 ? 1 : 2;
            if (slot==2) fail(17,0);
            else {
                Life *current=&life[slot];
                current->pid=event.dwProcessId;
                current->birth=birth_of(event.u.CreateProcessInfo.hProcess);
                current->threads=1;
                if (!DuplicateHandle(GetCurrentProcess(),event.u.CreateProcessInfo.hProcess,
                    GetCurrentProcess(),&current->retained,SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,0))
                    fail(18,GetLastError());
                if (slot==0) {
                    if (current->pid!=process.dwProcessId || !current->birth
                        || current->birth!=birth_of(process.hProcess)) fail(19,0);
                    if (!failure) {
                        assigned=AssignProcessToJobObject(job,process.hProcess);
                        if (!assigned) fail(20,GetLastError()); else bound=TRUE;
                    }
                }
                if (!IsProcessInJob(event.u.CreateProcessInfo.hProcess,job,&member))
                    fail(21,GetLastError());
                current->member=member;
                if (!member) fail(22,0);
                imageLength=MAX_PATH;
                if (!QueryFullProcessImageNameW(event.u.CreateProcessInfo.hProcess,0,imagePath,&imageLength)
                    || _wcsicmp(imagePath,helper)) fail(23,GetLastError());
                if (!event.u.CreateProcessInfo.hFile
                    || !GetFileInformationByHandle(event.u.CreateProcessInfo.hFile,&eventInfo)
                    || !same_file(&helperInfo,&eventInfo)) fail(24,GetLastError());
            }
            own_close(&event.u.CreateProcessInfo.hFile);
        } else if (slot==2) {
            fail(25,0);
            if (event.dwDebugEventCode==LOAD_DLL_DEBUG_EVENT) own_close(&event.u.LoadDll.hFile);
        } else {
            Life *current=&life[slot];
            switch (event.dwDebugEventCode) {
            case CREATE_THREAD_DEBUG_EVENT:
                if (++current->threads>64) fail(26,0);
                break;
            case LOAD_DLL_DEBUG_EVENT: own_close(&event.u.LoadDll.hFile); break;
            case EXCEPTION_DEBUG_EVENT:
                if (event.u.Exception.dwFirstChance && !current->breakpoint
                    && event.u.Exception.ExceptionRecord.ExceptionCode==EXCEPTION_BREAKPOINT)
                    current->breakpoint=TRUE;
                else { status=DBG_EXCEPTION_NOT_HANDLED; fail(27,event.u.Exception.ExceptionRecord.ExceptionCode); }
                break;
            case EXIT_PROCESS_DEBUG_EVENT:
                current->exitCode=event.u.ExitProcess.dwExitCode;
                if (exitSequence[slot]) fail(28,0);
                exitSequence[slot]=events;
                if (!cleanup && current->exitCode!=0) fail(28,current->exitCode);
                break;
            case EXIT_THREAD_DEBUG_EVENT: case UNLOAD_DLL_DEBUG_EVENT:
            case OUTPUT_DEBUG_STRING_EVENT: break; /* Metadata only; never read target memory. */
            case RIP_EVENT: fail(29,event.u.RipInfo.dwError); break;
            default: fail(29,event.dwDebugEventCode); break;
            }
        }
        /* Even a failing CREATE must be terminated before its first Continue. */
        if (failure && !cleanup) {
            cleanup=TRUE; cleanupDeadline=GetTickCount64()+5000;
            if (cleanupDeadline>start+20000) cleanupDeadline=start+20000;
            if (bound) { if (!TerminateJobObject(job,90)) cleanupError=GetLastError(); }
            else if (!TerminateProcess(process.hProcess,90)) cleanupError=GetLastError();
        }
        if (GetCurrentThreadId()!=osThread) { fail(36,0); incomplete=TRUE; break; }
        if (!ContinueDebugEvent(event.dwProcessId,event.dwThreadId,status)) {
            fail(37,GetLastError()); incomplete=TRUE; break;
        }
        ++continued;
        if (slot<2 && event.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT) life[slot].exitContinued=TRUE;
        sprintf_s(row,sizeof(row),
            "{\"seq\":%lu,\"ms\":%llu,\"thread\":%lu,\"event\":%lu,\"pid\":%lu,\"tid\":%lu,\"slot\":%lu,\"continueStatus\":%lu,\"continued\":true,\"failure\":%lu,\"error\":%lu}\n",
            events,GetTickCount64()-start,osThread,event.dwDebugEventCode,event.dwProcessId,
            event.dwThreadId,slot,status,failure,failureError);
        output(row);
    }
    sample_exit(&life[0]); sample_exit(&life[1]);
    own_close(&process.hThread); own_close(&process.hProcess);
    own_close(&life[0].retained); own_close(&life[1].retained);
    if (job) {
        if (QueryInformationJobObject(job,JobObjectBasicAccountingInformation,&account,sizeof(account),NULL)) {
            active=account.ActiveProcesses; total=account.TotalProcesses;
        } else fail(14,GetLastError());
    }
    if (active!=0 && launched) { incomplete=TRUE; if (!failure) fail(38,0); }
    own_close(&helperPin); own_close(&observerPin);
    own_close(&raw);
    own_close(&job);
    success=!failure && launched && bound && killOnExit && !cleanupError && !incomplete && ledgerClosed
        && life[0].member && life[1].member && life[0].breakpoint && life[1].breakpoint
        && life[0].exitContinued && life[1].exitContinued && life[0].signaled && life[1].signaled
        && life[0].referenceClosed && life[1].referenceClosed && active==0 && total==2
        && exitSequence[1] && exitSequence[0]>exitSequence[1] && events==continued;
    if (!success && !failure) fail(39,0);
    WideCharToMultiByte(CP_UTF8,0,run,-1,runA,sizeof(runA),NULL,NULL);
    WideCharToMultiByte(CP_UTF8,0,manifest,-1,manifestA,sizeof(manifestA),NULL,NULL);
    WideCharToMultiByte(CP_UTF8,0,helperSha,-1,helperA,sizeof(helperA),NULL,NULL);
    WideCharToMultiByte(CP_UTF8,0,observerSha,-1,observerA,sizeof(observerA),NULL,NULL);
    sprintf_s(receipt,sizeof(receipt),
        "{\"schemaVersion\":1,\"capabilityScope\":\"ownedSyntheticDebugLifecycle\",\"lifecycleSupported\":%s,"
        "\"runId\":\"%s\",\"manifestSha256\":\"%s\",\"helperSha256\":\"%s\",\"observerSha256\":\"%s\","
        "\"observerPid\":%lu,\"observerThread\":%lu,\"observerBirth\":%llu,"
        "\"helperFileId\":{\"volume\":%lu,\"high\":%lu,\"low\":%lu},"
        "\"observerFileId\":{\"volume\":%lu,\"high\":%lu,\"low\":%lu},"
        "\"parent\":{\"pid\":%lu,\"birth\":%llu,\"member\":%s,\"exit\":%lu,\"exitContinue\":%s,\"signaled\":%s,\"referenceClosed\":%s},"
        "\"child\":{\"pid\":%lu,\"birth\":%llu,\"member\":%s,\"exit\":%lu,\"exitContinue\":%s,\"signaled\":%s,\"referenceClosed\":%s},"
        "\"assignedBeforeContinue\":%s,\"killOnExit\":%s,\"events\":%lu,\"continued\":%lu,\"rawBytes\":%lu,"
        "\"activeProcesses\":%lu,\"totalProcesses\":%lu,\"ledgerClosed\":%s,\"cleanup\":%s,\"cleanupError\":%lu,"
        "\"evidenceIncomplete\":%s,\"failure\":%lu,\"error\":%lu,\"elapsedMs\":%llu,"
        "\"fileEffects\":\"NOT_OBSERVABLE\",\"networkEffects\":\"NOT_OBSERVABLE\",\"engineAcceptance\":\"notRun\"}\n",
        success?"true":"false",runA,manifestA,helperA,observerA,GetCurrentProcessId(),osThread,
        birth_of(GetCurrentProcess()),helperInfo.dwVolumeSerialNumber,helperInfo.nFileIndexHigh,helperInfo.nFileIndexLow,
        observerInfo.dwVolumeSerialNumber,observerInfo.nFileIndexHigh,observerInfo.nFileIndexLow,
        life[0].pid,life[0].birth,life[0].member?"true":"false",life[0].exitCode,life[0].exitContinued?"true":"false",
        life[0].signaled?"true":"false",life[0].referenceClosed?"true":"false",
        life[1].pid,life[1].birth,life[1].member?"true":"false",life[1].exitCode,life[1].exitContinued?"true":"false",
        life[1].signaled?"true":"false",life[1].referenceClosed?"true":"false",
        assigned?"true":"false",killOnExit?"true":"false",events,continued,bytes,active,total,
        ledgerClosed?"true":"false",cleanup?"true":"false",cleanupError,incomplete?"true":"false",
        failure,failureError,GetTickCount64()-start);
    receiptHandle=CreateFileW(receiptPath,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if (receiptHandle==INVALID_HANDLE_VALUE) return 40;
    if (!WriteFile(receiptHandle,receipt,(DWORD)strlen(receipt),&writeCount,NULL)
        || writeCount!=strlen(receipt)) { own_close(&receiptHandle); return 41; }
    own_close(&receiptHandle);
    return success && ledgerClosed ? 0 : 1;
}
