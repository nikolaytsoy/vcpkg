<#
.SYNOPSIS
Sets or replaces the GitHub tokens in this VM. Run it in the VM.

.DESCRIPTION
Asks for three tokens. Each one is optional: leave the prompt empty and press
Enter to skip it; a skipped token keeps its current value.

gh       Fine-grained, read-only (no permissions). gh signs in with it to read
         pull requests.
Copilot  Fine-grained, resource owner your account, permission "Copilot
         requests". Stored as the COPILOT_GITHUB_TOKEN user variable, which
         persists across reboots.
Fork     Fine-grained, resource owner your account, repository access only to
         your vcpkg fork, permission "Contents: Read and write". Stored in Git
         Credential Manager for git pushes over HTTPS.

Create or regenerate tokens on the host, never in this VM:
https://github.com/settings/personal-access-tokens
#>
$ErrorActionPreference = 'Stop'

function Read-Token([string]$Name) {
    [Net.NetworkCredential]::new('', (Read-Host "$Name token (leave empty to skip)" -AsSecureString)).Password
}

$gh = Read-Token 'gh'
$copilot = Read-Token 'Copilot'
$fork = Read-Token 'Fork'

if ($gh) {
    $gh | gh auth login --hostname github.com --with-token
    if ($LASTEXITCODE -ne 0) { throw 'gh auth login failed.' }
    Write-Host 'gh token set.'
}
if ($copilot) {
    [Environment]::SetEnvironmentVariable('COPILOT_GITHUB_TOKEN', $copilot, 'User')
    $env:COPILOT_GITHUB_TOKEN = $copilot
    Write-Host 'Copilot token set. Terminals that were open before keep the old value; open a new one.'
}
if ($fork) {
    # GitHub accepts any user name with a token; x-access-token is the conventional one.
    "protocol=https`nhost=github.com`nusername=x-access-token`npassword=$fork`n" | git credential approve
    if ($LASTEXITCODE -ne 0) { throw 'git credential approve failed.' }
    Write-Host 'Fork token passed to Git Credential Manager.'
}
