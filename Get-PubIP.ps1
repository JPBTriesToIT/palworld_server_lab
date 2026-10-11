# Determine the public IP of the machine running the script
$myIP = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
$sourcePrefix = "$myIP/32"
@{ sourcePrefix = $sourcePrefix } | ConvertTo-Json