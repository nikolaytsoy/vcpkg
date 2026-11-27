---
name: create-vm
description: >-
  Create an isolated Hyper-V Windows Server VM for running untrusted code,
  such as Copilot CLI in allow-all mode reviewing and testing vcpkg pull
  requests.
disable-model-invocation: true
---

## Goal

Create a Windows Server 2025 VM with the vcpkg CI toolchain and the vcpkg repository in `C:\vcpkg`, where the user runs Copilot CLI in allow-all mode, for example `review-vcpkg-prs-today`. After setup, the user connects to the VM and starts working; they do not need this skill again.

## Security model

Untrusted PR code runs in the VM with Copilot's rights and can read everything in it, including the tokens. The VM gets only optional, low-power fine-grained tokens, which the user enters in the VM with `C:\vcpkg\scripts\vm\Set-Tokens.ps1`:

| Token | Settings | Used by |
|---|---|---|
| gh | Read-only: no permissions | gh, to read pull requests |
| Copilot | Resource owner the user's account, "Copilot requests" | Copilot CLI, through the `COPILOT_GITHUB_TOKEN` user variable |
| Fork | Resource owner the user's account, only the user's vcpkg fork, "Contents: Read and write" | git pushes over HTTPS, through Git Credential Manager; see `fix-reviewed-vcpkg-pr` |

The scripts do not check the tokens; the user is responsible for their settings.

Limits: "Default Switch" is NAT through the host, so the VM reaches every network the host reaches, including the host itself. vmconnect enhanced sessions share the host clipboard, and host drives if they are selected in the connection options. Defender is removed.

## How to run

Run the whole procedure in one go. Before each step, tell the user in one sentence what happens now. Do not ask for permission to continue; stop only where the user must act or on a failure.

Scripts are in `scripts/` next to this file; `<scripts>` below is the absolute path of that folder. You run them on the host; `Initialize-VcpkgVm.ps1` sends `VcpkgVm.Guest.ps1` into the VM.

Run each elevated host script in async mode with:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & '<scripts>\Start-Elevated.ps1' -Script <script file name> -Parameters @{ <name> = <value>; ... }
```

Write string values in single quotes and double any `'` in them. `Start-Elevated.ps1` shows a UAC prompt and runs the script in a new elevated window. Before each run, tell the user to approve the UAC prompt and to type any requested password in that window. Secrets never go into the chat or a command line. Then end your turn; you are notified when the window closes. `Start-Elevated.ps1` then prints the output of the run and exits with the script's exit code; a non-zero code is a failure. To report progress while it runs, read `%TEMP%\create-vm.log`.

## Procedure

1. **Check the host.** Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File '<scripts>\Test-VcpkgVmHost.ps1'`.
2. **Enable Hyper-V** if step 1 shows it not enabled: run `Enable-HyperV.ps1`. The user restarts the host, then starts the skill again. If Hyper-V is enabled but not running, the user restarts the host or turns on virtualization in the firmware settings.
3. **Ask everything at once.** End your turn with this text block as your whole reply; text next to a tool call is shown only as a short note. Fill in the host values from step 1 and copy the rest word for word:

   ```text
   Host: <N> logical processors, <N> GB memory (<N> GB free now). Free space: <drive> <N> GB, ...
   The VM memory is static: it must be free on the host each time the VM starts.

   Download a Windows Server 2025 ISO, for example the evaluation ISO:
   https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025

   Reply when you have the ISO, and I will ask for the VM settings.
   ```

   After the user replies, ask all questions in one form, with short field descriptions. Do not download the ISO for the user, and do not look for ISO files on the user's machine.
   - vCPU and memory: prefill the suggested values from step 1; the user decides the final values.
   - VM name: default `vcpkg`; 1 to 15 letters, digits, or hyphens, not only digits.
   - Disk size: default 200 GB. The VHDX is dynamic and grows only as data is written.
   - VHDX folder: default the Hyper-V default folder.
   - ISO path: the full path of the downloaded ISO.
4. **Create the VM.** Run `New-VcpkgVm.ps1` with `Name`, `IsoPath`, `ProcessorCount`, `MemoryGB`, `DiskGB`, and `VhdFolder` if the user chose a folder. The user sets the password of the VM's Administrator account in the window. Tell them to save it, for example in a password manager: they need it to sign in to the VM and for step 5. Tell the user that the ISO and the new VHDX partitions appear as drives on the host for a while and not to open them. If the script fails while it waits for the first boot, the VM stays; ask the user to look at it in Hyper-V Manager.
5. **Set up the guest.** Run `Initialize-VcpkgVm.ps1` with `Name`. Add `RepoUrl` and `Branch` only if the user asks for another repository or branch than microsoft/vcpkg master. The user enters the VM password. It removes Defender, installs the vcpkg CI toolchain, clones the repository to `C:\vcpkg`, installs gh and VS Code Insiders, and takes the `clean-baseline` checkpoint. On failure, the output shows the last 30 lines of the failed step's log; if you need more, ask the user to open `%TEMP%\vcpkg-vm\<Step>.log` in the VM.
6. **Hand over.** Give the user the next section, with these token links as clickable Markdown links. Do not open them. Each token is optional; the user opens the link for each token they need on the host and clicks "Generate token". The fork token is only for fixes; `fix-reviewed-vcpkg-pr` explains it when it needs push access.
   - [gh token](https://github.com/settings/personal-access-tokens/new?name=vcpkg-vm-gh)
   - [Copilot token](https://github.com/settings/personal-access-tokens/new?name=vcpkg-vm-copilot&user_copilot_requests=read)

## Using the VM

1. Connect to the VM: run `vmconnect localhost <name>` from an elevated prompt, or open the VM in Hyper-V Manager. Sign in as Administrator.
2. Run `C:\vcpkg\scripts\vm\Set-Tokens.ps1` and paste each token you created. Leave a prompt empty and press Enter to skip that token.
3. Update vcpkg and start Copilot CLI:

   ```powershell
   cd C:\vcpkg
   git pull --ff-only
   .\bootstrap-vcpkg.bat -disableMetrics
   copilot --yolo
   ```

   The first `copilot` run asks to install Copilot CLI; answer `y`. If it asks you to `/login`, add the Copilot token with `Set-Tokens.ps1` instead: a token you create yourself with only "Copilot requests" is safer.
4. To review pull requests: `/review-vcpkg-prs-today investigation-root C:\vcpkg-prs`. The vcpkg repository is in `C:\vcpkg`; to open it in VS Code Insiders: `code-insiders C:\vcpkg`.

To replace an expired token, regenerate it on the host at https://github.com/settings/personal-access-tokens, then run `Set-Tokens.ps1` again and skip the others. After restoring the `clean-baseline` checkpoint, run it again for all tokens.

### Optional: Linux and Android builds with WSL containers

The VM has nested virtualization, so it can run WSL containers (`wslc`) with the vcpkg CI images. The arm64-linux and Android images are x64 images that cross-compile.

1. In the VM, run `C:\vcpkg\scripts\vm\Install-Wslc.ps1`, then restart the VM.
2. Run `C:\vcpkg\scripts\vm\New-WslcImages.ps1` to build the images from the Dockerfiles in `C:\vcpkg\scripts\azure-pipelines`, with the CI image names. Add `-Image linux` to build only the x64 Linux image.

Use `wslc` only in a signed-in VM session. A WSL session started over PowerShell Direct from the host leaves WSL broken after that session ends, until `Restart-Service WSLService`.
