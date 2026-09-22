<#
.SYNOPSIS
  Doubao Skin Studio - Windows pause
.DESCRIPTION
  暂停皮肤，恢复原生界面（不重启客户端）
.PARAMETER Port
  CDP 调试端口。豆包默认 9333，豆包工作默认 9334
.PARAMETER Client
  客户端：auto、personal 或 work
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [ValidateSet('auto', 'personal', 'work')]
  [string]$Client = 'auto'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Resolve-DoubaoClient {
  if ($Client -ne 'auto') { return $Client }
  if ($env:DOUBAO_CLIENT -in @('personal', 'work')) { return $env:DOUBAO_CLIENT }

  try {
    $cursor = $PID
    for ($depth = 0; $depth -lt 20 -and $cursor -gt 0; $depth++) {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId = $cursor" -ErrorAction Stop
      $identity = "$($process.ExecutablePath) $($process.CommandLine)"
      if ($identity -match '[\\/]DoubaoWork(\.exe|[\\/])') { return 'work' }
      if ($identity -match '[\\/]Doubao(\.exe|[\\/])') { return 'personal' }
      $cursor = [int]$process.ParentProcessId
    }
  } catch {}

  if ($Root -match '[\\/](DoubaoWork)[\\/]' -or $Root -match '[\\/]\.doubaowork[\\/]') {
    return 'work'
  }
  if ($Root -match '[\\/](Doubao)[\\/]' -or $Root -match '[\\/]\.doubao[\\/]') {
    return 'personal'
  }

  $workRunning = [bool](Get-Process DoubaoWork -ErrorAction SilentlyContinue)
  $personalRunning = [bool](Get-Process Doubao -ErrorAction SilentlyContinue)
  if ($workRunning -and -not $personalRunning) { return 'work' }
  return 'personal'
}

function Find-Node {
  $g = Get-Command node -ErrorAction SilentlyContinue
  if ($g) { return $g.Source }
  return $null
}

function Test-CDP([int]$P, [string]$RendererHint) {
  try {
    $r = Invoke-RestMethod "http://127.0.0.1:$P/json/list" -TimeoutSec 1
    return [bool]($r | Where-Object { $_.type -eq 'page' -and $_.url -like "*$RendererHint*" })
  } catch { return $false }
}

$clientId = Resolve-DoubaoClient
$rendererHint = if ($clientId -eq 'work') { 'doubaowork-chat' } else { 'doubao-chat' }

# 皮肤可能被注入在非默认端口（新版 aha-runtime 占用 9333/9334 时 apply 会自动换端口）。
# 用户显式 -Port 时只用它；否则遍历候选端口，挑一个真正暴露 renderer 的来还原。
if ($PSBoundParameters.ContainsKey('Port') -and $Port -ne 0) {
  $candidatePorts = @($Port)
} elseif ($clientId -eq 'work') {
  $candidatePorts = @(9334, 9344, 9345, 9346, 9347)
} else {
  $candidatePorts = @(9333, 9335, 9336, 9337, 9338)
}
$Port = $candidatePorts[0]
foreach ($p in $candidatePorts) {
  if (Test-CDP $p $rendererHint) { $Port = $p; break }
}
if ($Port -lt 1024 -or $Port -gt 65535) {
  Write-Error "Port 必须是 1024 到 65535 的整数"
  exit 1
}

$node = Find-Node
if (-not $node) { Write-Error "未找到 node。"; exit 1 }
Write-Host "Client: $(if ($clientId -eq 'work') { '豆包工作' } else { '豆包' })"
& $node (Join-Path $Root 'src/cli.mjs') pause --client $clientId --port $Port
