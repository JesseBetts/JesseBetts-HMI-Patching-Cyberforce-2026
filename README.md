# JesseBetts-HMI-Patching-Cyberforce-2026
 This is the patch I made to use on my compromised Windows 2019 server machine.

Here are the commands needed to run the script

New-Item -ItemType Directory -Force C:\Temp | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-WebRequest -UseBasicParsing `
  -Uri "https://raw.githubusercontent.com/JesseBetts/JesseBetts-HMI-Patching-Cyberforce-2026/main/Patch-HMI.ps1" `
  -OutFile C:\Temp\Patch-HMI.ps1
  
Unblock-File C:\Temp\Patch-HMI.ps1

powershell -ExecutionPolicy Bypass -File C:\Temp\Patch-HMI.ps1 #you can add "-ReportOnly" to the end to just see the report.
