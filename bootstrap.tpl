<powershell>
New-Item -ItemType Directory -Path "C:\Scripts" -Force | Out-Null

$bytes = [Convert]::FromBase64String("${script_content}")
[System.IO.File]::WriteAllBytes("C:\Scripts\Install-WinGetAndPowerShell7.ps1", $bytes)

$bytes2 = [Convert]::FromBase64String("${steamcmd_script}")
[System.IO.File]::WriteAllBytes("C:\Scripts\Install-SteamPSandSteamCMD.ps1", $bytes2)

</powershell>