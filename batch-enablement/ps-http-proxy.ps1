
Write-Host "Provide proxy details"
$proxyURL = Read-Host "Proxy URL (eg: http://contoso.squid.local:3128)"
if ($proxyURL -eq "") {
  Write-Host "No proxy URL provided. Skipping proxy configuration."
  return
}
if ($proxyURL.StartsWith("http") -ne $true) {
  $proxyURL = "http://$proxyURL"
}

$noProxy = Read-Host "No Proxy (comma separated, press enter to skip)"

$env:http_proxy = $proxyURL
$env:HTTP_PROXY = $proxyURL
$env:https_proxy = $proxyURL
$env:HTTPS_PROXY = $proxyURL
$env:no_proxy = $noProxy
$env:NO_PROXY = $noProxy

$proxyCA = Read-Host "Proxy CA cert path (Press enter to skip)"
if ($proxyCA -ne "") {
  $proxyCA = Resolve-Path -Path $proxyCA
  $env:REQUESTS_CA_BUNDLE = $proxyCA
}

$credential = $null
$proxyAddr = $proxyURL

if ($proxyURL.Contains("@")) {
  $x = $proxyURL.Split("//")
  $proto = $x[0]
  $x = $x[2].Split("@")
  $userPass = $x[0]
  $proxyAddr = $proto + "//" + $x[1]
  $x = $userPass.Split(":")
  $proxyUsername = $x[0]
  $proxyPassword = $x[1]
  $password = ConvertTo-SecureString -String $proxyPassword -AsPlainText -Force
  $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $proxyUsername, $password
}

[system.net.webrequest]::defaultwebproxy = new-object system.net.webproxy($proxyAddr)
[system.net.webrequest]::defaultwebproxy.credentials = $credential
[system.net.webrequest]::defaultwebproxy.BypassProxyOnLocal = $true
