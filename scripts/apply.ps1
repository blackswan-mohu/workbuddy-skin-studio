<#
.SYNOPSIS
  Doubao Skin Studio - Windows apply
.DESCRIPTION
  应用当前主题到豆包或豆包工作桌面端。自动识别调用本技能的客户端，
  优先直接连上注入；仅当对应客户端的 CDP 不可达时才重启该客户端。
.PARAMETER Port
  CDP 调试端口。豆包默认 9333，豆包工作默认 9334
.PARAMETER Client
  客户端：auto、personal 或 work
.PARAMETER DoubaoExe
  显式指定 Doubao.exe 路径（覆盖自动探测）
.PARAMETER Theme
  指定主题 id（默认用 jade-rabbit）
.EXAMPLE
  .\apply.ps1
  .\apply.ps1 -Theme chinese-dragon
  .\apply.ps1 -DoubaoExe "D:\apps\Doubao\Doubao.exe"
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [ValidateSet('auto', 'personal', 'work')]
  [string]$Client = 'auto',
  [string]$DoubaoExe,
  [string]$Theme
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

function Get-ClientConfig([string]$ClientId) {
  if ($ClientId -eq 'work') {
    return @{
      Id = 'work'
      Name = '豆包工作'
      ProcessName = 'DoubaoWork'
      Executable = 'DoubaoWork.exe'
      InstallDirectory = 'DoubaoWork'
      EnvironmentVariable = 'DOUBAO_WORK_EXE'
      Port = 9334
      # 候选调试端口：新版豆包 aha-runtime 会抢占 9334 只暴露 node 端点，逐个换干净端口
      CandidatePorts = @(9334, 9344, 9345, 9346, 9347)
      RendererHint = 'doubaowork-chat'
    }
  }
  return @{
    Id = 'personal'
    Name = '豆包'
    ProcessName = 'Doubao'
    Executable = 'Doubao.exe'
    InstallDirectory = 'Doubao'
    EnvironmentVariable = 'DOUBAO_EXE'
    Port = 9333
    CandidatePorts = @(9333, 9335, 9336, 9337, 9338)
    RendererHint = 'doubao-chat'
  }
}

function Find-DoubaoExe($Config) {
  if ($DoubaoExe -and (Test-Path -LiteralPath $DoubaoExe)) { return $DoubaoExe }
  $environmentPath = [Environment]::GetEnvironmentVariable($Config.EnvironmentVariable)
  if ($environmentPath -and (Test-Path -LiteralPath $environmentPath)) { return $environmentPath }

  $relative = Join-Path $Config.InstallDirectory $Config.Executable
  $candidates = @()
  if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA $relative
    $candidates += Join-Path $env:LOCALAPPDATA (Join-Path 'Programs' $relative)
  }
  if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles $relative }
  if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} $relative }
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  # 注册表 Uninstall 项
  try {
    $keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($k in $keys) {
      Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$($Config.ProcessName)*" -and $_.InstallLocation } | ForEach-Object {
        $p = Join-Path $_.InstallLocation $Config.Executable
        if (Test-Path -LiteralPath $p) { return $p }
      }
    }
  } catch {}
  return $null
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
$config = Get-ClientConfig $clientId
if ($Port -eq 0) { $Port = $config.Port }
if ($Port -lt 1024 -or $Port -gt 65535) {
  Write-Error "Port 必须是 1024 到 65535 的整数"
  exit 1
}

$node = Find-Node
if (-not $node) {
  Write-Error "未找到 node。请安装 Node.js 18+ 并确保 node 在 PATH。"
  exit 1
}

Write-Host "Client: $($config.Name)"
Write-Host "Node: $node"
Write-Host "Port: $Port"

# 候选端口列表：用户显式 -Port 时只用它；否则用客户端的候选端口组（应对 aha-runtime 抢占）
$candidatePorts = if ($PSBoundParameters.ContainsKey('Port') -and $Port -ne 0) { @($Port) } else { $config.CandidatePorts }

# 1) 免重启快速路径：任一候选端口已有可注入 renderer，直接用它
$readyPort = 0
foreach ($p in $candidatePorts) {
  if (Test-CDP $p $config.RendererHint) { $readyPort = $p; break }
}

if ($readyPort -ne 0) {
  $Port = $readyPort
  Write-Host "CDP 已就绪（端口 $Port），直接注入，无需重启豆包"
} else {
  $exe = Find-DoubaoExe $config
  if (-not $exe) {
    Write-Error "CDP 未就绪，且未找到 $($config.Executable)。请用 -DoubaoExe 参数或设置环境变量 $($config.EnvironmentVariable)"
    exit 1
  }
  Write-Host "$($config.Name): $exe"
  Write-Host "CDP 未就绪，退出$($config.Name)并以调试模式重启（当前对话请先保存）..."
  Get-Process $config.ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2

  # 2) 逐个候选端口尝试：带该端口重启→等出现可注入 page renderer→锁定；
  #    新版 aha-runtime 会占用 9333/9334 只暴露 node 端点，遇到就换下一个干净端口。
  $Port = 0
  foreach ($cand in $candidatePorts) {
    Write-Host "以 CDP 调试模式启动（尝试端口 $cand）..."
    Start-Process -FilePath $exe -ArgumentList "--remote-debugging-address=127.0.0.1","--remote-debugging-port=$cand"
    $deadline = (Get-Date).AddSeconds(25)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
      if (Test-CDP $cand $config.RendererHint) { $ok = $true; break }
      Start-Sleep -Milliseconds 400
    }
    if ($ok) { $Port = $cand; Write-Host "renderer 就绪（端口 $Port）"; break }
    Write-Host "端口 $cand 未出现 renderer（可能被 aha-runtime 占用），换下一个..."
    Get-Process $config.ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }

  if ($Port -eq 0) {
    Write-Error "所有候选端口均未拿到 renderer，换肤失败。候选：$($candidatePorts -join ', ')"
    exit 1
  }
}

Write-Host "应用皮肤..."
$cli = Join-Path $Root 'src/cli.mjs'
$applyArgs = @('apply', '--client', $clientId, '--port', "$Port")
if ($Theme) { $applyArgs += @('--theme', $Theme) }
& $node $cli @applyArgs
