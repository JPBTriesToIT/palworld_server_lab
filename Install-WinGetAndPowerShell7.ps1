# Install the required package provider and client module
Install-PackageProvider -Name NuGet -Force
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery

# Use the repair cmdlet to download and install the WinGet client and dependencies
Repair-WinGetPackageManager -AllUsers

# Install Powershell 7 using winget
winget install Microsoft.PowerShell --source winget
