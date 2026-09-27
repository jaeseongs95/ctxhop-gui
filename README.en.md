# CtxHop GUI vNext (Windows)

[한국어](README.md) | English

Back up Claude Code and Codex Desktop conversations from one window and restore them on another PC. The GUI runs on Windows PowerShell 5.1, which comes with Windows. It does not replace the existing `ctxhop-gui` package or your existing storage.

> **Preview.** All isolated tests pass, but a real round trip of a conversation between two PCs has not been run yet. Start with a short test conversation.

## What you need

- Windows with Windows PowerShell 5.1.
- A folder that both PCs can see, such as a Google Drive folder. The GUI keeps the encrypted backups there. Anyone who can write to this folder can plant backups or make later backups readable to them, so use a folder of your own that you do not share (see the security review in `verification.md`).
- For **Codex Desktop**:
  - Codex Desktop engine `0.158.0-alpha.2` or `0.158.0-alpha.2.1`. The PC that made a backup and the PC that restores it must run **exactly the same** engine version. Otherwise the restore is blocked before anything is written.
  - Python from the Codex Desktop install (`%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`). To use another Python 3.10 or later, put `{"pythonPath":"absolute path"}` in `backend\runtime.json` on that PC. The GUI does not use Python from PATH and does not install one.

## Install

Download either the installer or the zip from [Releases](https://github.com/jaeseongs95/ctxhop/releases); both contain the same GUI. First check that the file matches the SHA256 shown on the release page.

**Installer (recommended)**

1. Run `CtxHop-GUI-vNext-<date>-setup.exe`. The installer is unsigned, so Windows may show **Windows protected your PC**; click **More info** → **Run anyway**.
2. It installs without admin rights to `%LOCALAPPDATA%\Programs\CtxHop GUI vNext` and adds a **CtxHop GUI vNext** shortcut to the Start menu and, if you keep that option, the desktop. Installed files need no unblocking.
3. Start it from the last setup page or later from the shortcut.

- Install a newer build over the old one with its installer.
- While a GUI task (list, backup, restore, setup) is running, setup and uninstall ask you to wait until it finishes, then continue.
- To remove it, go to Windows **Settings** → **Apps** → **Installed apps** and uninstall **CtxHop GUI vNext**. GUI settings and job folders in `%LOCALAPPDATA%\CtxHopGUI` and the ctxhop configuration are left in place. A `backend\runtime.json` you created stays in the install folder.
- The installer is built from [`installer/CtxHop-GUI-vNext.iss`](installer/CtxHop-GUI-vNext.iss) (Inno Setup 6.7).

**Zip**

1. **Unblock the zip before extracting it.** Right-click the zip → **Properties** → check **Unblock**, or run `Unblock-File .\CtxHop-GUI-vNext-<date>.zip`. If you skip this, Windows blocks the extracted `.ps1` files and the GUI silently does not open. If you already extracted it, delete that folder and extract the unblocked zip again.
2. Extract the zip and run `ctxhop-gui-vnext\Run-CtxHop-GUI-vNext.cmd`.

The installer and the zip include `bin\ctxhop.exe` and `bin\ctxhop-claude.exe`. These builds are not in the repository. See [Integrity checks](#integrity-checks).

**Update both PCs to this build.** It moves subagent conversations together with their parent conversation. Earlier builds cannot read the Codex shared backups this build makes and stop before writing, and Claude companion folders move only between PCs on this build.

## First-time setup

Use the **Connection · Invite** tab.

1. **Language / 언어**: choose 한국어 (Korean) or English, then restart the GUI. Screens and job messages switch language. Block reasons from the Python backend and output from the ctxhop, Codex, and Claude executables stay in their original language.
2. If this PC already uses ctxhop, click **Check connection** and skip the rest. The GUI keeps the existing settings, and **Set up / Join by invite** refuses to run over them.
3. **First PC**: make an empty folder in the shared folder, then set it as **Drive store path**. Leave **Invite (other PC)** empty, enter **This PC name**, and click **Set up / Join by invite**. A task window opens where you type the password yourself.
   - The settings sync question (`[Y/n]`) treats Enter as Y. **Type `n`**. With Y, this GUI cannot back up.
   - If the two passwords differ or you mistype the recovery key confirmation, nothing is saved. Click the same button again.
   - Keep the recovery key from this step somewhere safe and offline.
4. **Other PC**: on the first PC, click **Create invite for another PC**. Copy the invite JSON to the other PC. There, choose it under **Invite (other PC)**, enter **This PC name**, and click **Set up / Join by invite**.
5. A PC that finished setup uses its device authorization, so it does not ask for the password when you list, back up, or restore.

## Back up and restore Claude Code conversations

On the **Backup · Restore** tab, choose **Claude Code** as the agent.

1. Choose the project folder, type a shared **Identity**, and click **Register project**. Use the same Identity for the same project on every PC. Registered folders appear under **Registered projects**.
   - Do not register a parent folder and one of its child folders with **different Identities**. ctxhop then refuses to list or register anything inside them, so the GUI blocks such a registration.
   - If two registrations already overlap, pick one under **Registered projects** and click **Unregister**. Conversation files and backups are not deleted. If the folder was already deleted, it is unregistered only when that Identity has exactly one registration and it is this path.
2. Click **Load conversations** and select one conversation.
3. Click **Back up selected**, or **Preview and restore** to bring a shared backup to this PC. The GUI checks the source ID, the project, and the executable hash, blocks environment changes, and keeps a recovery record while it restores.
4. **Open selected** opens the conversation in Claude Code.

Close Claude Code and any editor that can start it, such as VS Code, Cursor, or Windsurf, before a backup or restore. If one is running, the error lists the programs and PIDs to close.

Claude Code keeps a folder with the same name next to each conversation file (`<session ID>.jsonl`). It holds subagent transcripts (`subagents\`) and saved tool results (`tool-results\`). Backup and restore move this folder with the conversation.

- A restore never deletes files that only this PC has. For each file whose content changes, the original is kept in the `.companion` folder next to the recovery record.
- Files are copied as they are. Paths written inside them are not changed to this PC's folders.
- Backups made by an earlier build have no such folder, so only the conversation file comes back, and the completion message says so. Back up again with this build on the source PC to move the folder too.
- The folder is uploaded only when you back up with this GUI. If another ctxhop, such as a Claude Code hook's automatic push, later uploads only the conversation, the restored folder is the one from the last GUI backup.

## Back up and restore Codex Desktop conversations

Choose **Codex Desktop** as the agent and check the **Codex data folder** on the settings tab (default `%USERPROFILE%\.codex`).

### List

The list loads all projects, archived conversations, and shared backups. You can search by title, UUID, or source folder, and the list shows 200 rows per page. When you reload, the search also goes to the backend. The list reads metadata page by page and never scans conversation bodies.

- **This project only** (on by default) filters the list by the **Project** folder.
  - Conversations on this PC appear only if they were started in that folder or below it.
  - Shared backups appear if their source folder is the same or below it, or if their last folder name is the same. This way a project folder with the same name on another PC shows up even if its path differs. A different project with the same folder name can show up too, so check the source folder in the restore preview.
  - A leading `\\?\`, letter case, and a trailing `\` are ignored. Clear the box to see all projects.
- Line breaks in titles become spaces in the shared backup list. The conversation itself does not change.
- Subagent conversations do not get their own rows. They travel with their parent conversation as one group, and the parent row's context column shows how many there are as `· N subagents`. Subagent conversations whose parent conversation is missing are not shown and are not backed up.
- Shared backups made by an earlier build are marked `· older format`. They contain only the parent conversation, so restoring one brings back only the parent.
- Unsupported conversations, such as ones with registered dynamic tools, stop with a reason before anything is written. If any conversation in a group is unsupported, the whole group stops.

### Back up

1. Select one local conversation and click **Back up selected**. The Codex app may stay open.

A backup only reads, so you do not need to quit the Codex app. If that conversation or one of its subagent conversations is in progress right now (its last turn has not finished and something was written in the last 15 minutes), it is skipped so that a half-written record is never backed up. Try again after the turn finishes. A conversation that changes while it is being backed up is skipped for the same reason. A conversation whose turn was cut off, for example when the app was forced to quit, is backed up once 15 minutes have passed.

Each backup is a separate encrypted snapshot that holds the parent conversation and all of its subagent conversations. Several backups with the same UUID appear as separate rows. The GUI never picks one by date and never overwrites one.

**Back up all filtered** backs up, one by one, every conversation on this PC that matches the current filter (This project only, search, view, date), across all pages.
- It first shows how many it will back up and skip and asks you to confirm. The Codex app may stay open; conversations in progress are counted as **in progress** and skipped. Each conversation takes a few seconds.
- Conversations that already have a shared backup with the same UUID and modification time are skipped, so running it again uploads only conversations that changed. The modification time is the latest one in the group, so a change in a subagent conversation alone also triggers a new backup. `Older format` backups have no subagent conversations and do not count as up to date.
- If one conversation fails, it moves on to the next and shows the done, skipped, in progress and failed counts with the reasons at the end. It stops after 3 failures in a row, for example when the store cannot be written. Conversations skipped as in progress do not count as failures.
- Click **Cancel task** once to stop after the current conversation, or again to stop the task window right away.
- If anything was backed up, the list reloads to show the new backups.

### Restore

1. Choose the real working folder the conversation should use, and make sure the Drive app finished downloading.
2. Select one or more shared backups and click **Preview and restore**. The check does not change local conversation files or the DB. To read the engine version, Codex may create a temporary file in `tmp\arg0` under `%CODEX_HOME%` (or `%USERPROFILE%\.codex`), which Codex cleans up on its next run.
3. The review window lists every item: conversations missing on this PC, identical histories, shared histories that extend the local one, local histories that extend the shared one, diverged histories, and items that cannot be restored.
   - Every row starts as **Skip**. **Keep local** also writes nothing.
   - On each row you want, choose **Restore backup** yourself. You can pick only one backup per UUID.
   - Damaged or malformed items have no restore option.
   - A conversation with subagent conversations is judged as one group. If any subagent conversation diverged, the whole group counts as diverged, and you choose restore or skip for the group. The reason column counts the subagent conversations by state.
   - A restore leaves alone subagent conversations that are newer on this PC or exist only on this PC.
   - Every conversation in the group uses the working folder chosen in step 1, even a subagent conversation that originally ran in another folder.
4. Check your choices and the working folder, then approve the restore. If the Codex app is running, the backend stops and asks you to quit it. The GUI never force-closes the Codex or Claude apps. If the check token, backup file, ID, data folder, or target folder changes, run the check again.
5. Open Codex Desktop yourself and check the UUID, the content, and the working folder. The GUI sends no prompt and no CLI resume command. Prepare project files, Git state, and tools separately.

## Troubleshooting

### The GUI does not open

If you used the zip, it was probably extracted without being unblocked. Delete the extracted folder, unblock the zip (see [Install](#install)), and extract it again. The installer does not have this problem; try the shortcut again, and if the GUI still does not open, run the installer again to reinstall over it.

### A task fails or seems stuck

- **Failure reason**: when a ctxhop command fails, the error window shows the exit code and the reason ctxhop logged, such as overlapping project registrations or a password mismatch. The GUI reads the reason from that day's log in `%USERPROFILE%\.ctxhop\logs` (or `logs` under `CTXHOP_CONFIG_DIR`).
- **Settings sync is on**: if a backup says settings sync was turned on (Y) at setup, close the GUI and task windows. Then change `"syncConfig"` to `"disabled"` in the `config.json` that the message names, and try again.
- **Cancel task**: click **Cancel task** at the bottom. It stops only the task window the GUI started and the ctxhop or Python process inside it. The Codex and Claude apps are not touched. If you cancelled a backup, back up again. **Restore and Open cannot be cancelled.** Wait for a restore to finish, and close an opened conversation yourself.
- **Forgot or want to change the password**: on **Connection · Invite**, **Change password** asks for the current password, then the new one twice. **Reset password with recovery key** asks for the recovery key from setup, then the new password twice. Both run in a task window, and the recovery key does not change.

### A Claude restore was interrupted

While a `*.pending.json` remains in `%LOCALAPPDATA%\CtxHopGUI\recovery`, Claude backup, restore, and open are paused.

1. Close Claude Code and editors such as VS Code or Cursor.
2. Open the `*.pending.json`. Each entry in `originals` has three fields:
   - `original`: the path of the conversation file before the restore.
   - `backup`: a copy saved next to the recovery record (`*.original.jsonl`).
   - `sha256`: the copy's SHA256.

   To go back to the state before the restore, copy the `backup` file over the `original` path. If `originals` is empty, the restore was adding a conversation that was not on this PC. Check the new conversation in Claude Code.

   Originals of changed files in the companion folder are in the `.companion` folder named by `companionBackup`, under the same relative paths. To bring them back, copy them to the same places in the `<session ID>\` folder next to the conversation file.
3. **Move** the `*.pending.json` out of the recovery folder (do not delete it). This lifts the block.

### A Codex restore failed

After a failure, the GUI does not apply the remaining items. It shows the recovery records from the backend (the list of `pending` folders), and keeps the source backups and those records. While an interrupted record remains, later backups and restores are blocked. **With the Codex app closed**, check and recover from the GUI folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action pending -HomePath 'Codex data folder from the GUI settings tab'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action recover -HomePath 'Codex data folder from the GUI settings tab' -Run 'exact folder listed by pending'
```

- `-HomePath` must be **the same string** as the Codex data folder on the settings tab. Do not end it with `\`, because `powershell.exe -File` reads a trailing `\'` as a quote. The command then stops before writing and says the folder does not exist. These commands use the same Python and the same pinned backend hash as the GUI.
- `recover` returns the conversation to its state before the import. It stops on its own if the app rewrote that conversation after the interruption, or if the DB was only partly created.
- `recover` checks only that the app is closed and the DB structure, not the engine version. After a Codex update it still works if the DB structure is the same. Otherwise it stops before writing. In that case use the next step (bringing back `before.zip` needs the same engine version, so it is not possible then).
- **If recovery stopped, or the import finished but only its completion record remains**: do not repeat recovery. Check the conversation with that UUID in the Codex app. To keep the current state, **move** the folder listed by `pending` out of `.ctxhop-desktop-recovery` (do not delete it). Inside, `before.zip` is this PC's whole group (parent and subagent conversations) before the import, and numbered files such as `incoming-0000.zip` hold the imported content of each conversation. Recovery folders left by an earlier build have a single `incoming.zip`. Moving the folder lifts the block.

### Undo a restore that replaced a local history

When you restore a shared backup over a diverged history, this PC's previous history, the whole group including subagent conversations, stays in `<Codex data folder>\.ctxhop-desktop-recovery\<job ID>\before.zip`. Find the folder for that UUID and time. To bring it back, quit the app, check the file as the restore source, then apply it with the `token` from the output:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action inspect -HomePath 'Codex data folder' -Archive '...\before.zip' -Cwd 'working folder of that conversation'
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\backend\Invoke-Desktop.ps1 -Action apply -HomePath 'Codex data folder' -Archive '...\before.zip' -Cwd 'working folder of that conversation' -Token 'token from the output above' -Choice incoming
```

This apply also saves the history it replaces in a new recovery folder. The recovery copy records this PC's engine version at restore time, so if the engine changed since then, the apply is blocked before writing and the data stays intact.

## Reference

### Files and folders

- Preferences: `%LOCALAPPDATA%\CtxHopGUI\vnext-preferences.json`
- Temporary job requests and results: `%LOCALAPPDATA%\CtxHopGUI\jobs`
- Codex backup and check files: `%LOCALAPPDATA%\CtxHopGUI\staging\<unique ID>`.
  - Each job makes a new folder that only the current user can open.
  - When a backup upload or a restore succeeds, the GUI deletes that job's plaintext copy.
  - Folders from failed or cancelled jobs and from skipped previews stay behind for the restore token and failure evidence. Delete them yourself when you no longer need them.
  - Do not upload the plaintext conversations in this folder to Drive.
- Claude recovery records: `%LOCALAPPDATA%\CtxHopGUI\recovery`
- Codex recovery records: `<Codex data folder>\.ctxhop-desktop-recovery`
- ctxhop settings and logs: `%USERPROFILE%\.ctxhop` (or `CTXHOP_CONFIG_DIR`)

The GUI never overwrites a whole session folder or DB.

### Integrity checks

- `Worker.ps1` pins the SHA256 of `backend\desktop_sessions.py` and `bin\ctxhop.exe`, and checks them before Codex list, backup, and preview. If either file is missing or changed, the GUI stops.
- `bin\ctxhop-claude.exe` must match the pinned `0.2.0-gui.2` hash before a Claude preview or restore. It is `0.2.0-gui.1` plus companion folder backup and restore (`--sidecar-backup`); its source, patch and build record are in `claude-source\`.
- `ClaudeWorker.ps1` is a copy of the stable `ctxhop-gui` Worker (SHA256 `D08E9A15…`). It adds the chosen language, failure reasons, the overlapping-registration check, unregistering, and password change and reset. Its backup and restore decisions and its recovery records are unchanged.
- `Worker.ps1` connects the frozen Python backend to the `bundle` command of `bin\ctxhop.exe`. The UI never parses conversation bodies, the DB, or archive formats itself.
- Screen and job text in both languages lives in `Strings.ps1` as `key=@('Korean','English')`.
- New Codex Desktop engine versions must be verified with `backend\test_suite.py` and then added to `VERSIONS`.

### Isolated tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-ClaudeWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-ClaudeGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopWorker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-DesktopGUI.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Test-DesktopIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Test-Strings.ps1
& "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" -X utf8 .\backend\test_suite.py --exe 'absolute path of the installed Desktop codex.exe'
```

- The first four use a new temporary folder and synthetic metadata. They mock the backend, the transfer, Codex, and Claude.
- `Test-DesktopIntegration.ps1` creates a test conversation in a temporary folder with the installed Codex Desktop engine. It then calls the **pinned real backend** through the Worker; only the transfer is mocked.
- `Test-Strings.ps1` checks that the strings in both languages pair up and share placeholders. It also looks for untranslated Hangul in the code and checks the English screens and error messages.
- `backend\test_suite.py` uses an isolated `CODEX_HOME` and fixed localhost responses to create a paginated conversation with the real engine. It then checks porting, reading, and resuming.

Results and hashes are in `verification.md` (in Korean). Building and testing did not change the production repository, real user sessions, authentication settings, or the global execution policy.
