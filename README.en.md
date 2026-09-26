# CtxHop vNext review candidate

[한국어](README.md) | English

A separate candidate that backs up and restores Claude Code and Codex Desktop conversations from one window. It does not replace the existing `ctxhop-gui` package or the user's storage. Start it with `Run-CtxHop-GUI-vNext.cmd`. It uses Windows PowerShell 5.1 and WinForms.

For the Codex path, `Worker.ps1` pins the SHA256 of `backend\desktop_sessions.py` and of the encrypted bundle executable `bin\ctxhop.exe`. If either file is missing or changed, the GUI stops.

- **Python**: uses the runtime installed by Codex Desktop, `%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`. To use another Python 3.10 or later, put `{"pythonPath":"absolute path"}` in `backend\runtime.json` on that PC. It does not use Python from PATH or install one automatically.
- **Supported engines**: Codex Desktop `0.158.0-alpha.2` and `0.158.0-alpha.2.1`. For an import, **the engine version of the PC that made the backup must exactly match this PC's**; if they differ, the import is blocked before anything is written. It is also blocked if the DB structure differs from the pinned structure. When the app updates to a new version, re-verify with `backend\test_suite.py`, then add the version to `VERSIONS`.
- Line breaks in titles become spaces in the shared backup list. The conversation content does not change.
- Subagent conversations appear in the list but are marked **Blocked**. Select the parent conversation. Other unsupported conversations, such as ones with registered dynamic tools, stop with a reason before anything is written when you click **Back up selected**.
- An actual round trip of a conversation between two PCs has not been run yet. Start with a short test conversation.
- **Language**: choose 한국어 (Korean) or English under **Language / 언어** on the settings tab (**Connection · Invite**). After you restart the program, the screens and job messages use that language. Block reasons returned by the Python backend and text printed by the ctxhop, Codex, and Claude executables stay in their original language.

## How to use

1. In **Connection · Invite**, check the existing ctxhop connection. A new PC connects with the invitation JSON made on the source PC. If a password is needed, type it yourself in the job input window, and answer **n** to the settings sync question.
2. **Claude Code**: register the project folder and a shared name, then select one conversation as before. The existing checks stay in place: source ID, project, blocking environment application, executable hash, and recovery records.
3. **Codex Desktop**: check the Codex data folder on the settings tab. The list includes all projects, archived conversations, and shared backups. You can search by title, UUID, or source folder, and the list shows 200 rows per page. When you reload the list, the search is also passed to the backend list query. The list reads metadata page by page and does not scan conversation bodies.
4. **Codex backup**: quit the app yourself, then select one local conversation and back it up. A shared backup is stored as a separate encrypted snapshot. Several backups with the same UUID appear as separate rows; the GUI never picks one automatically by modified date or overwrites one.
5. **Codex restore**: select the actual target working folder and confirm that the Drive download is complete. Select one or more shared backups, then click **Preview and restore**. The check does not change local conversation files or the DB. However, to check the engine version during the check, Codex may create a temporary file in `tmp\arg0` under `%CODEX_HOME%` (or `%USERPROFILE%\.codex` if it is not set). Codex cleans it up on its next run.
6. The per-item review window shows all of these together: conversations not on this PC, identical histories, shared histories that extend the local one, local histories that extend the shared one, diverged histories, and items that cannot be restored. Every row defaults to **Skip**. **Keep local** also writes nothing. On each row you want to restore, choose **Restore backup** yourself. For one UUID, you can choose only one backup to restore. Damaged or malformed items have no restore option.
7. Check your choices and the working folder, then approve the restore in the final approval window. If the Codex app is running, the backend stops and asks you to quit the app yourself. The GUI does not force-close the app or any job process. If the check token, backup file, ID, data folder, or target folder changes, you must run the check again.
8. After the restore, open Codex Desktop yourself and check the UUID, the conversation content, and the working folder. The GUI sends no automatic prompt or CLI resume command. Prepare project files, Git state, and tool installs separately.

If a restore fails, the GUI does not apply the next item automatically. It shows the raw recovery records returned by the backend (the list of `pending` folders). The source backups and the pending recovery records are kept. While an interrupted record remains, later backups and restores are blocked, so check and recover from this folder **with the Codex app closed**.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action pending -HomePath 'Codex data folder from the GUI settings tab'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action recover -HomePath 'Codex data folder from the GUI settings tab' -Run 'exact folder listed by pending'
```

- `-HomePath` must be **the same string** as the Codex data folder on the GUI settings tab (default `%USERPROFILE%\.codex`). These commands also use the same Python as the GUI (the default path or `backend\runtime.json`) and the pinned backend hash. Do not end the path with `\`. When run with `powershell.exe -File`, a trailing `\'` is read as a quote and breaks the path (the command then stops before writing, saying the folder does not exist).
- `recover` returns to the state before the import. If the app rewrote that conversation after the interruption, or the DB was only partly created, it stops on its own.
- `recover` checks only that the app is closed and the DB structure; it does not check the engine version. If Codex updates after a failure, you can still recover as long as the DB structure is the same. If the structure changed, it stops before writing. In that case, follow the procedure right below for moving the pending folder (bringing back `before.zip` needs the same engine version, so it is not possible here).
- **If recovery stopped, or the import finished but only the completion record remains**: do not repeat automatic recovery. Check the conversation with that UUID in the Codex app. To keep the current state, **move** (do not delete) the folder listed by `pending` to a storage location outside `.ctxhop-desktop-recovery`. In that folder, `before.zip` is the original from before the import, and `incoming.zip` is the imported content. Moving the folder lifts the block.
- **Going back to the original local history after overwriting it with a shared backup**: even after you restore a shared backup over a diverged history, this PC's previous history stays in `<Codex data folder>\.ctxhop-desktop-recovery\<job ID>\before.zip` (find the folder for that UUID and time). To bring it back, quit the app, check this file as the restore source, then apply it with the `token` from the output. This apply also saves the history it replaces in a new recovery folder. The recovery copy records this PC's engine version at the time of the restore, so if the engine has changed since then, the apply is blocked before writing because the engine differs (the data stays intact).

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action inspect -HomePath 'Codex data folder' -Archive '...\before.zip' -Cwd 'working folder of that conversation'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action apply -HomePath 'Codex data folder' -Archive '...\before.zip' -Cwd 'working folder of that conversation' -Token 'token from the output above' -Choice incoming
```
- The GUI never overwrites a whole session folder or DB. The existing Claude recovery behavior stays unchanged in the copied worker.

## Local files and candidate boundaries

- Preferences: `%LOCALAPPDATA%\CtxHopGUI\vnext-preferences.json`
- Temporary job requests and results: `%LOCALAPPDATA%\CtxHopGUI\jobs`
- Codex backup and check files: `%LOCALAPPDATA%\CtxHopGUI\staging\<unique ID>`. Each job creates a new folder and new files, and only the current user can access them. When a backup upload or a restore succeeds, the GUI deletes that job's plaintext copy. Folders from failed jobs and from skipped or canceled previews stay behind for the restore token and failure evidence; delete them yourself when you no longer need them. Do not upload the plaintext conversations in this folder to Drive.
- Claude: `ClaudeWorker.ps1` is a copy of the existing stable Worker (SHA256 `D08E9A15…`). It moves the screen and error text to `Strings.ps1` and adds only two lines that apply the request's language. `bin/ctxhop-claude.exe` must match the existing `0.2.0-gui.1` hash.
- Text: the Korean and English text for screens and job messages lives in `Strings.ps1` as `key=@('Korean','English')`.
- Codex: `Worker.ps1` connects the frozen Python backend to the bundle command of `bin/ctxhop.exe`. The UI does not parse conversation bodies, the DB, or archive formats itself.

The full modified Claude source is not duplicated here. Building and testing this candidate did not change the production repository, real user sessions, authentication settings, or the global execution policy.

## Isolated tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-ClaudeWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-ClaudeGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-DesktopGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-Strings.ps1
& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" -X utf8 .\backend\test_suite.py --exe 'absolute path of the installed Desktop codex.exe'
```

The first four use a new temporary folder and synthetic metadata, and replace the backend, transport, Codex, and Claude runs with mocks. `Test-DesktopIntegration.ps1` creates a test conversation in a temporary folder with the installed Codex Desktop engine, then calls the **pinned real backend** through the Worker (only the transfer is mocked). `Test-Strings.ps1` checks that the strings in the two languages pair up and share placeholders, looks for untranslated Hangul left in the code, and checks the English screens and English error messages. `backend\test_suite.py` uses an isolated `CODEX_HOME` and fixed localhost responses to create a paginated conversation with the real engine, then checks porting, reading, and resuming. Results and hashes are in `verification.md` (in Korean).
