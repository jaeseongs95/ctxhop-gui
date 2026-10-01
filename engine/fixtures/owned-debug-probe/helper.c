#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

/* Synthetic fixture only: no data access, reporting, or configuration loading. */
int wmain(int argc, wchar_t **argv)
{
    wchar_t image[MAX_PATH], command[2 * MAX_PATH];
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    LPWCH environment;
    DWORD code = 1;
    if (argc != 5 || wcscmp(argv[1], L"--role") || wcscmp(argv[3], L"--run")
        || wcslen(argv[4]) != 32 || wcsspn(argv[4], L"0123456789abcdef") != 32)
        return 2;
    if (!wcscmp(argv[2], L"child")) return 0;
    if (wcscmp(argv[2], L"parent")) return 2;
    if (!GetModuleFileNameW(NULL, image, MAX_PATH) || wcschr(image, L'"')) return 3;
    if (swprintf_s(command, 2 * MAX_PATH, L"\"%ls\" --role child --run %ls",
                   image, argv[4]) < 0) return 3;
    startup.cb = sizeof(startup);
    /* No debug-chain reset, breakaway, handle inheritance, or implicit PATH. */
    environment = GetEnvironmentStringsW();
    if (!environment) return 4;
    if (!CreateProcessW(image, command, NULL, NULL, FALSE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
        environment, NULL, &startup, &process)) {
        FreeEnvironmentStringsW(environment); return 4;
    }
    FreeEnvironmentStringsW(environment);
    if (WaitForSingleObject(process.hProcess, 5000) != WAIT_OBJECT_0
        || !GetExitCodeProcess(process.hProcess, &code)) code = 5;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return code == 0 ? 0 : 5;
}
