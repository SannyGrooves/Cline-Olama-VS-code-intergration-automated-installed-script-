#Requires -Version 5.1
<#
.SYNOPSIS
    Local AI coding setup: VS Code + Cline + Ollama + Cline CLI/Desktop/SDK, with
    Qwen3.6 27B (Q5_K_M) running on your NVIDIA GPU via Ollama.

.DESCRIPTION
    Interactive, idempotent (safe to re-run), self-elevating installer for
    Windows 10/11 and PowerShell 5.1+. Everything is logged to
    %LOCALAPPDATA%\ClineLocalSetup\logs.

    Notes:
      * keep_alive is NOT a Modelfile parameter in Ollama. This script sets it
        through the OLLAMA_KEEP_ALIVE environment variable (and per request in
        the connection test). num_ctx / num_gpu / sampling go in the Modelfile.
      * The Cline VS Code extension keeps its provider settings in VS Code's own
        storage, which cannot be written safely from outside. The script prints
        (and copies to the clipboard) the exact values to enter, and it DOES
        configure the Cline CLI non-interactively.
      * Run it as the same Windows user you use day to day. If UAC asks for a
        DIFFERENT admin account, per-user installs land in that account's profile.

.PARAMETER Unattended
    Run the full automatic install with defaults (Q5_K_M, detected hardware).

.PARAMETER NoElevate
    Do not self-elevate (some steps may fail without admin rights).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-ClineLocalAI.ps1
#>
[CmdletBinding()]
param(
    [switch]$Unattended,
    [switch]$NoElevate
)

# ============================================================================
# 0. SELF-ELEVATION
# ============================================================================
if (-not $PSCommandPath) {
    Write-Host 'Please save this script as a .ps1 file and run it from disk.' -ForegroundColor Red
    exit 1
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    if ($NoElevate) {
        Write-Host 'WARNING: running without administrator rights; some installs may fail.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Requesting administrator rights (UAC)...' -ForegroundColor Cyan
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        if ($Unattended) { $relaunch += '-Unattended' }
        try {
            Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunch -Verb RunAs
            exit 0
        }
        catch {
            Write-Host 'Elevation was cancelled or failed. Exiting.' -ForegroundColor Red
            exit 1
        }
    }
}

# ============================================================================
# 1. GLOBALS, CONSTANTS, PATHS
# ============================================================================
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$Script:Version      = '1.0.0'
$Script:Unattended   = [bool]$Unattended
$Script:AppDir       = Join-Path $env:LOCALAPPDATA 'ClineLocalSetup'
$Script:LogDir       = Join-Path $Script:AppDir 'logs'
$Script:SecretsDir   = Join-Path $Script:AppDir 'secrets'
$Script:ModelfileDir = Join-Path $Script:AppDir 'modelfiles'
$Script:ConfigFile   = Join-Path $Script:AppDir 'config.json'
$Script:LogFile      = Join-Path $Script:LogDir ('setup-{0:yyyyMMdd}.log' -f (Get-Date))
foreach ($d in $Script:AppDir, $Script:LogDir, $Script:SecretsDir, $Script:ModelfileDir) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$Script:Const = @{
    Q5Ref              = 'hf.co/bartowski/Qwen_Qwen3.6-27B-GGUF:Q5_K_M'
    Q5SizeGB           = 19.7                       # approx. file size
    OfficialRef        = 'qwen3.6:27b'              # official Ollama build (Q4_K_M)
    OfficialSizeGB     = 17.0
    ExtId              = 'saoudrizwan.claude-dev'   # Cline VS Code extension
    MinVsCode          = [version]'1.84.0'
    MinNodeMajor       = 22                         # Cline CLI + SDK need Node 22+
    DesktopFallbackUrl = 'https://github.com/cline/cline/releases/download/desktop-v0.0.49/Cline_0.0.49_x64-setup.exe'
    DefaultLayers      = 64                         # used only if /api/show gives no block_count
}

# Persistent settings (hardware profile + choices). Missing keys get defaults.
$Script:Cfg = [ordered]@{
    GpuName       = ''
    VramGB        = 0.0
    RamGB         = 0.0
    FreeDiskGB    = 0.0          # 0 = measure live
    OffloadToRam  = $true
    ContextSize   = 'auto'       # auto | 4k | 8k | 16k | 32k | 64k | 128k | number
    KvCache       = 'q8_0'       # q8_0 (saves memory) | f16
    KeepAlive     = '30m'        # becomes OLLAMA_KEEP_ALIVE
    BaseUrl       = 'http://localhost:11434'
    ModelRef      = ''           # base model that was pulled
    TunedName     = ''           # Modelfile-tuned model used by Cline
    EffectiveCtx  = 0
    EffectiveGpu  = -1
    Workspace     = ''
    EnvVarsSet    = @()
    ApiProviders  = @()
}

$Script:Results   = New-Object System.Collections.ArrayList
$Script:LastError = ''

# ============================================================================
# 2. LOGGING + COLORED OUTPUT
# ============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO',
        [switch]$NoConsole
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -Path $Script:LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8 } catch { }
    if ($NoConsole) { return }
    switch ($Level) {
        'OK'    { Write-Host "  [ OK ] $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [FAIL] $Message" -ForegroundColor Red }
        'STEP'  { Write-Host "`n==> $Message" -ForegroundColor Cyan }
        'DEBUG' { Write-Host "  $Message" -ForegroundColor DarkGray }
        default { Write-Host "  [INFO] $Message" -ForegroundColor Gray }
    }
}
function Write-Info { param([string]$m) Write-Log $m 'INFO' }
function Write-Ok   { param([string]$m) Write-Log $m 'OK' }
function Write-Warn { param([string]$m) Write-Log $m 'WARN' }
function Write-Fail { param([string]$m) Write-Log $m 'ERROR' }
function Write-Step { param([string]$m) Write-Log $m 'STEP' }

# Runs a scriptblock; logs and swallows errors so the menu loop keeps running.
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "BEGIN $Name" 'DEBUG' -NoConsole
    try {
        $null = & $Action
        Write-Log "END $Name" 'DEBUG' -NoConsole
        return $true
    }
    catch {
        $Script:LastError = $_.Exception.Message
        Write-Fail "$Name failed: $($_.Exception.Message)"
        Write-Log ($_ | Out-String) 'ERROR' -NoConsole
        return $false
    }
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    [void]$Script:Results.Add([pscustomobject]@{ Step = $Name; Status = $Status; Detail = $Detail })
}
function Invoke-Tracked {
    param([string]$Name, [scriptblock]$Action)
    $ok = Invoke-Step $Name $Action
    if ($ok) { Add-Result $Name 'OK' } else { Add-Result $Name 'FAILED' $Script:LastError }
    return $ok
}

# ============================================================================
# 3. INPUT HELPERS (all return defaults in -Unattended mode)
# ============================================================================
function Read-Default {
    param([string]$Prompt, [string]$Default = '')
    if ($Script:Unattended) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $v = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    if ($Script:Unattended) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $v = (Read-Host "$Prompt ($hint)").Trim().ToLower()
        if ($v -eq '') { return $Default }
        if ($v -in 'y', 'yes') { return $true }
        if ($v -in 'n', 'no')  { return $false }
    }
}

function Read-Number {
    param([string]$Prompt, [double]$Default = 0, [double]$Min = 0, [double]$Max = 1000000)
    if ($Script:Unattended) { return $Default }
    while ($true) {
        $raw = Read-Default $Prompt ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Default))
        $n = 0.0
        if ([double]::TryParse($raw, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -ge $Min -and $n -le $Max) {
            return $n
        }
        Write-Warn "Enter a number between $Min and $Max."
    }
}

function Wait-Enter {
    if (-not $Script:Unattended) { [void](Read-Host "`nPress Enter to continue") }
}

# ============================================================================
# 4. CONFIG PERSISTENCE
# ============================================================================
function Save-Config {
    try {
        $json = $Script:Cfg | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($Script:ConfigFile, $json, (New-Object Text.UTF8Encoding($false)))
    }
    catch { Write-Warn "Could not save config: $($_.Exception.Message)" }
}

function Import-Config {
    if (-not (Test-Path $Script:ConfigFile)) { return }
    try {
        $loaded = Get-Content -Path $Script:ConfigFile -Raw | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) {
            if ($Script:Cfg.Contains($p.Name)) { $Script:Cfg[$p.Name] = $p.Value }
        }
        $Script:Cfg.EnvVarsSet  = @($Script:Cfg.EnvVarsSet)
        $Script:Cfg.ApiProviders = @($Script:Cfg.ApiProviders)
    }
    catch { Write-Warn "Config file unreadable, using defaults: $($_.Exception.Message)" }
}

# ============================================================================
# 5. TOOL / PATH / WINGET HELPERS
# ============================================================================
# Re-read PATH from the registry so freshly installed tools are found immediately.
function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
    $npm = Join-Path $env:APPDATA 'npm'
    if ((Test-Path $npm) -and -not $env:Path.ToLower().Contains($npm.ToLower())) { $env:Path += ";$npm" }
}

function Get-ToolPath {
    param([string]$Name, [string[]]$Extra = @())
    $c = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c -and $c.Source) { return $c.Source }
    foreach ($p in $Extra) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}
function Get-CodeExe   { Get-ToolPath 'code'   @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") }
function Get-OllamaExe { Get-ToolPath 'ollama' @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", "$env:ProgramFiles\Ollama\ollama.exe") }
function Get-ClineCli  { Get-ToolPath 'cline'  @("$env:APPDATA\npm\cline.cmd") }
function Get-NvidiaSmi { Get-ToolPath 'nvidia-smi' @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:SystemRoot\System32\nvidia-smi.exe") }

# Runs a native command and captures output + exit code (never throws on stderr).
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments = @())
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode = -1; Output = @("Command not found: $Exe") }
    }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($null -eq $code) { $code = 0 }
    return [pscustomobject]@{ ExitCode = $code; Output = @($out) }
}

# Runs a native command with live console output (progress bars etc.).
function Invoke-Live {
    param([string]$Exe, [string[]]$Arguments = @())
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    if ($null -eq $code) { $code = 0 }
    return $code
}

function Confirm-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Write-Warn 'winget (Microsoft App Installer) was not found.'
    if (Read-YesNo 'Try to install App Installer from https://aka.ms/getwinget now?' $true) {
        try {
            $tmp = Join-Path $env:TEMP 'AppInstaller.msixbundle'
            Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $tmp -UseBasicParsing
            Add-AppxPackage -Path $tmp
            Update-SessionPath
        }
        catch { Write-Fail "App Installer setup failed: $($_.Exception.Message)" }
    }
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Install-WingetPkg {
    param([string]$Id, [string]$Name, [switch]$Upgrade)
    if (-not (Confirm-Winget)) { throw "winget is required to install $Name. Install 'App Installer' from the Microsoft Store." }
    $verb = if ($Upgrade) { 'upgrade' } else { 'install' }
    Write-Info "winget $verb $Id (this can take a few minutes)..."
    $r = Invoke-Native 'winget' @($verb, '--id', $Id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    $r.Output | Select-Object -Last 10 | ForEach-Object { Write-Log $_ 'DEBUG' -NoConsole }
    # 0 = ok, -1978335189 = nothing to upgrade, -1978335135 = already installed, 3010 = reboot needed
    if ($r.ExitCode -in 0, -1978335189, -1978335135, 3010) {
        if ($r.ExitCode -eq 3010) { Write-Warn "$Name installed; a reboot may be required." }
        Update-SessionPath
        return
    }
    throw "winget exited with code $($r.ExitCode) while installing $Name."
}

# ============================================================================
# 6. HARDWARE PROFILE (detect, confirm or enter manually)
# ============================================================================
function Get-OllamaModelsDir {
    $d = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
    if (-not $d) { $d = $env:OLLAMA_MODELS }
    if (-not $d) { $d = Join-Path $env:USERPROFILE '.ollama\models' }
    return $d
}

function Get-FreeDiskGB {
    param([string]$Path)
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        if (-not $root) { $root = "$($env:SystemDrive)\" }
        $di = New-Object IO.DriveInfo($root)
        return [math]::Round($di.AvailableFreeSpace / 1GB, 1)
    }
    catch { return 0 }
}

function Get-DetectedGpus {
    $list = @()
    $smi = Get-NvidiaSmi
    if ($smi) {
        $r = Invoke-Native $smi @('--query-gpu=name,memory.total', '--format=csv,noheader,nounits')
        if ($r.ExitCode -eq 0) {
            foreach ($line in $r.Output) {
                if ($line -match '^(.+),\s*(\d+)\s*$') {
                    $list += [pscustomobject]@{
                        Name   = $Matches[1].Trim()
                        VramGB = [math]::Round([double]$Matches[2] / 1024, 1)
                        Source = 'nvidia-smi'
                    }
                }
            }
        }
    }
    if ($list.Count -eq 0) {
        # Fallback: WMI knows the name but AdapterRAM is capped at 4 GB, so VRAM stays unknown.
        try {
            foreach ($v in (Get-CimInstance Win32_VideoController)) {
                $list += [pscustomobject]@{ Name = $v.Name; VramGB = 0.0; Source = 'WMI' }
            }
        }
        catch { }
    }
    return $list
}

function Convert-CtxSetting {
    param([string]$Setting)
    $s = $Setting.Trim().ToLower()
    if ($s -eq 'auto') { return 0 }
    if ($s -match '^(\d+)\s*k$') { return [int]$Matches[1] * 1024 }
    if ($s -match '^\d+$') { return [int]$s }
    return 0
}

function Initialize-Hardware {
    param([switch]$Force)
    Write-Step 'Hardware profile'
    $c = $Script:Cfg
    $have = ($c.GpuName -and [double]$c.VramGB -gt 0 -and [double]$c.RamGB -gt 0)
    if ($have -and -not $Force) {
        Write-Info ("Saved profile: {0}, {1} GB VRAM, {2} GB RAM, offload to RAM: {3}, context: {4}" -f
            $c.GpuName, $c.VramGB, $c.RamGB, $(if ($c.OffloadToRam) { 'yes' } else { 'no' }), $c.ContextSize)
        if (Read-YesNo 'Use the saved hardware profile?' $true) { return }
    }

    # --- GPU -----------------------------------------------------------------
    $gpus = @(Get-DetectedGpus)
    $name = ''; $vram = 0.0
    if ($gpus.Count -gt 0) {
        $g = $gpus[0]
        Write-Info ("Detected GPU: {0} ({1}{2})" -f $g.Name, $(if ($g.VramGB -gt 0) { "$($g.VramGB) GB" } else { 'VRAM unknown' }), " via $($g.Source)")
        if ($gpus.Count -gt 1) { Write-Warn "Multiple GPUs found; using the first one for planning. Ollama may still split across GPUs." }
        if (Read-YesNo 'Is this correct?' $true) { $name = $g.Name; $vram = $g.VramGB }
    }
    if (-not $name) {
        if ($Script:Unattended) { throw 'No GPU detected and running unattended; run interactively once to enter it manually.' }
        $name = Read-Default 'GPU name (e.g. NVIDIA GeForce RTX 4070 Ti)' 'Unknown GPU'
    }
    if ($vram -le 0) { $vram = Read-Number 'GPU VRAM in GB' 12 0 192 }
    else { $vram = Read-Number 'GPU VRAM in GB (Enter to confirm)' $vram 0 192 }

    # --- RAM -----------------------------------------------------------------
    $ram = 0.0
    try { $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0) } catch { }
    $ram = Read-Number 'System RAM in GB (Enter to confirm)' $(if ($ram -gt 0) { $ram } else { 32 }) 2 4096

    # --- Disk ----------------------------------------------------------------
    $free = Get-FreeDiskGB (Get-OllamaModelsDir)
    Write-Info "Free disk on the Ollama model drive: $free GB"
    $override = 0.0
    if (-not (Read-YesNo 'Use the measured free-disk value?' $true)) { $override = Read-Number 'Free disk in GB' $free 0 100000 }

    # --- Optimisation options ------------------------------------------------
    $offload = Read-YesNo 'Allow offloading model layers to system RAM (needed when the model is bigger than VRAM)?' $true
    $ctx = ''
    while ($true) {
        $ctx = (Read-Default 'Context size: auto / 4k / 8k / 16k / 32k / 64k / 128k / number' $c.ContextSize).ToLower()
        if ($ctx -match '^(auto|\d+k?)$') { break }
        Write-Warn 'Please enter auto, e.g. 16k, or a number such as 24576.'
    }
    $ctxVal = Convert-CtxSetting $ctx
    if ($ctxVal -gt 0 -and $ctxVal -lt 16384) { Write-Warn 'Cline sends a large system prompt (~10k+ tokens). Below 16k the agent will struggle.' }
    $kv = if (Read-YesNo 'Quantize the KV cache to q8_0 (saves memory, needs flash attention)?' ($c.KvCache -eq 'q8_0')) { 'q8_0' } else { 'f16' }
    $ka = Read-Default 'Keep model loaded in memory for (e.g. 10m, 30m, 2h, -1 = forever)' $c.KeepAlive

    $c.GpuName = $name; $c.VramGB = $vram; $c.RamGB = $ram; $c.FreeDiskGB = $override
    $c.OffloadToRam = $offload; $c.ContextSize = $ctx; $c.KvCache = $kv; $c.KeepAlive = $ka
    Save-Config
    Write-Ok 'Hardware profile saved.'
}

# ============================================================================
# 7. OFFLOAD / CONTEXT PLANNER
#    Estimates how many layers fit in VRAM. These are heuristics (KV-cache cost
#    and layer sizes vary per architecture); Ollama still makes the final call.
# ============================================================================
function Get-OffloadPlan {
    param([double]$ModelGB, [int]$Layers, [string]$CtxSetting, [int]$ModelMaxCtx = 0)
    $c = $Script:Cfg
    $vram = [double]$c.VramGB
    $ram  = [double]$c.RamGB
    $kvPer1k   = if ($c.KvCache -eq 'q8_0') { 0.05 } else { 0.10 }   # GB per 1k tokens (estimate)
    $usableVram = [math]::Max(0.0, $vram - 1.5)                      # Windows desktop + CUDA context
    $usableRam  = if ($c.OffloadToRam) { [math]::Max(0.0, $ram - 8.0) } else { 0.0 }

    $ctx = Convert-CtxSetting $CtxSetting
    if ($ctx -le 0) {
        # auto: largest tier (max 32k, for speed) whose KV cache fits in the leftover memory
        $headroom = ($usableVram + $usableRam) - $ModelGB
        $ctx = 4096
        foreach ($tier in 32768, 16384, 8192, 4096) {
            if (($tier / 1000.0) * $kvPer1k * 1.25 -le $headroom) { $ctx = $tier; break }
        }
    }
    if ($ModelMaxCtx -gt 0 -and $ctx -gt $ModelMaxCtx) { $ctx = $ModelMaxCtx }

    $kvGB     = ($ctx / 1000.0) * $kvPer1k
    $perLayer = $ModelGB / [math]::Max(1, $Layers)
    $kvLayer  = $kvGB / [math]::Max(1, $Layers)
    $gpuLayers = [int][math]::Floor($usableVram / ($perLayer + $kvLayer))
    if ($gpuLayers -gt $Layers) { $gpuLayers = $Layers }
    if ($gpuLayers -lt 0) { $gpuLayers = 0 }
    $fitsAll = ($gpuLayers -ge $Layers)
    $cpuGB   = [math]::Round(($Layers - $gpuLayers) * ($perLayer + $kvLayer), 1)

    if ($c.OffloadToRam) { $numGpu = if ($fitsAll) { 999 } else { $gpuLayers } }
    else                 { $numGpu = 999 }     # user wants everything on the GPU

    return [pscustomobject]@{
        Ctx = $ctx; NumGpu = $numGpu; GpuLayers = $gpuLayers; Layers = $Layers
        ModelGB = $ModelGB; KvGB = [math]::Round($kvGB, 1); CpuGB = $cpuGB
        FitsAll = $fitsAll; FitsRam = ($cpuGB -le $usableRam); UsableRam = $usableRam
    }
}

# ============================================================================
# 8. REQUIREMENTS CHECK
# ============================================================================
function Test-Requirements {
    param([double]$ModelGB = 0)
    Write-Step 'Requirements check'
    $c = $Script:Cfg
    $blocking = $false
    if ($ModelGB -le 0) { $ModelGB = 10; Write-Info 'Model size unknown; assuming at least 10 GB.' }

    # OS
    $os = [Environment]::OSVersion.Version
    if ($os.Major -ge 10) { Write-Ok "Windows $($os.Major).$($os.Minor) build $($os.Build)" }
    else { Write-Warn 'Windows 10 or newer is required.'; $blocking = $true }

    # GPU / driver
    $smi = Get-NvidiaSmi
    if ($smi) {
        $r = Invoke-Native $smi @('--query-gpu=driver_version', '--format=csv,noheader')
        Write-Ok "NVIDIA driver present (nvidia-smi OK, driver $($r.Output | Select-Object -First 1))"
    }
    else { Write-Warn 'nvidia-smi not found: no NVIDIA driver detected (menu 2 can help).' }

    # Disk
    $free = if ([double]$c.FreeDiskGB -gt 0) { [double]$c.FreeDiskGB } else { Get-FreeDiskGB (Get-OllamaModelsDir) }
    $need = [math]::Round($ModelGB * 1.1 + 3, 1)
    if ($free -lt $ModelGB) { Write-Fail "Only $free GB free; the model alone needs about $ModelGB GB."; $blocking = $true }
    elseif ($free -lt $need) { Write-Warn "$free GB free; about $need GB recommended (model + working space)." }
    else { Write-Ok "Disk: $free GB free (need about $need GB)." }

    # RAM / VRAM
    $total = [double]$c.RamGB + [double]$c.VramGB
    if ([double]$c.RamGB -lt 16) { Write-Warn "RAM is $($c.RamGB) GB; 32 GB+ is recommended for a 27B model with CPU offload." }
    else { Write-Ok "RAM: $($c.RamGB) GB" }
    if ([double]$c.VramGB -gt 0) {
        if ([double]$c.VramGB -lt 8) { Write-Warn "VRAM is $($c.VramGB) GB; expect heavy CPU offload and slow generation." }
        else { Write-Ok "VRAM: $($c.VramGB) GB" }
    }
    if ($total -lt ($ModelGB + 6)) { Write-Warn "RAM + VRAM ($total GB) is barely above the model size ($ModelGB GB); loading may fail or crawl." }
    if (-not $c.OffloadToRam -and [double]$c.VramGB -lt ($ModelGB + 2)) {
        Write-Warn 'RAM offload is OFF but the model is larger than VRAM: it will likely fail to load. Enable offload in the hardware profile (H).'
    }

    # Low disk: offer to move the models folder to another drive
    if ($free -lt $need -and -not $Script:Unattended) {
        if (Read-YesNo 'Store Ollama models on a different drive/folder?' $false) { Set-OllamaModelsDir }
    }
    return $blocking
}

function Set-OllamaModelsDir {
    $p = Read-Default 'Folder for Ollama models (e.g. D:\ollama\models)' ''
    if (-not $p) { return }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $p, 'User')
    $env:OLLAMA_MODELS = $p
    $Script:Cfg.EnvVarsSet = @($Script:Cfg.EnvVarsSet + 'OLLAMA_MODELS' | Select-Object -Unique)
    Save-Config
    Write-Ok "OLLAMA_MODELS = $p (existing models are not moved). Ollama will restart when needed."
}

# ============================================================================
# 9. COMPONENT INSTALLERS (idempotent: detect first, install only if missing)
# ============================================================================
function Ensure-NvidiaDriver {
    Write-Step 'NVIDIA driver'
    if (Get-NvidiaSmi) { Write-Ok 'nvidia-smi found; driver is installed.'; return }
    $hasNvidia = $false
    try { $hasNvidia = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' }) } catch { }
    if (-not $hasNvidia) {
        Write-Warn 'No NVIDIA GPU found. Ollama can use AMD (ROCm/Vulkan) or run on CPU, but this script is tuned for NVIDIA.'
        return
    }
    Write-Warn 'NVIDIA GPU found but nvidia-smi is missing: the driver is not installed or is broken.'
    Write-Info 'Drivers cannot be installed fully silently via winget; the NVIDIA App can download one for you.'
    if (Read-YesNo 'Try installing the NVIDIA App via winget (id Nvidia.NVIDIAApp)?' $true) {
        try { Install-WingetPkg 'Nvidia.NVIDIAApp' 'NVIDIA App' }
        catch { Write-Warn "winget could not install it: $($_.Exception.Message)" }
    }
    Write-Info 'Download the latest Game Ready/Studio driver, install it, reboot, then re-run this script.'
    if (Read-YesNo 'Open https://www.nvidia.com/Download/index.aspx now?' $true) { Start-Process 'https://www.nvidia.com/Download/index.aspx' }
}

function Ensure-Git {
    Write-Step 'Git'
    if (Get-ToolPath 'git') {
        $v = (Invoke-Native 'git' @('--version')).Output | Select-Object -First 1
        Write-Ok $v; return
    }
    Install-WingetPkg 'Git.Git' 'Git'
    $gitCmd = Join-Path $env:ProgramFiles 'Git\cmd'
    if ((Test-Path $gitCmd) -and -not (Get-ToolPath 'git')) { $env:Path += ";$gitCmd" }
    if (-not (Get-ToolPath 'git')) { throw 'Git was installed but is not on PATH yet; open a new terminal and re-run.' }
    Write-Ok 'Git installed.'
}

function Get-NodeVersion {
    $n = Get-ToolPath 'node'
    if (-not $n) { return $null }
    $r = Invoke-Native $n @('--version')
    if ($r.ExitCode -eq 0) {
        try { return [version](($r.Output | Select-Object -First 1).ToString().Trim().TrimStart('v')) } catch { }
    }
    return $null
}

function Ensure-Node {
    Write-Step 'Node.js'
    $min = $Script:Const.MinNodeMajor
    $v = Get-NodeVersion
    if ($v -and $v.Major -ge $min) { Write-Ok "Node.js $v"; return }
    if ($v) {
        Write-Warn "Node.js $v found. Cline CLI and the SDK need Node $min+ (the extension itself only needs 20+)."
        if (-not (Read-YesNo "Upgrade to Node.js LTS via winget?" $true)) { return }
        try { Install-WingetPkg 'OpenJS.NodeJS.LTS' 'Node.js LTS' -Upgrade }
        catch { Write-Info 'Upgrade path failed; trying a fresh install.'; Install-WingetPkg 'OpenJS.NodeJS.LTS' 'Node.js LTS' }
    }
    else { Install-WingetPkg 'OpenJS.NodeJS.LTS' 'Node.js LTS' }
    Update-SessionPath
    $v = Get-NodeVersion
    if (-not $v) { throw 'Node.js installed but not found on PATH; open a new terminal and re-run.' }
    if ($v.Major -lt $min) { Write-Warn "Node.js is $v (< $min). CLI/SDK steps may fail." } else { Write-Ok "Node.js $v" }
}

function Get-VsCodeVersion {
    $c = Get-CodeExe
    if (-not $c) { return $null }
    $r = Invoke-Native $c @('--version')
    if ($r.ExitCode -eq 0) { try { return [version]($r.Output | Select-Object -First 1).ToString().Trim() } catch { } }
    return $null
}

function Ensure-VSCode {
    Write-Step 'Visual Studio Code'
    $min = $Script:Const.MinVsCode
    $v = Get-VsCodeVersion
    if ($v -and $v -ge $min) { Write-Ok "VS Code $v"; return }
    if ($v) {
        Write-Warn "VS Code $v is older than $min (required by Cline). Upgrading."
        Install-WingetPkg 'Microsoft.VisualStudioCode' 'VS Code' -Upgrade
    }
    else { Install-WingetPkg 'Microsoft.VisualStudioCode' 'VS Code' }
    Update-SessionPath
    $v = Get-VsCodeVersion
    if (-not $v) { throw 'VS Code installed but the "code" command was not found; open a new terminal and re-run.' }
    Write-Ok "VS Code $v"
}

function Ensure-Ollama {
    Write-Step 'Ollama'
    $exe = Get-OllamaExe
    if ($exe) { Write-Ok ((Invoke-Native $exe @('--version')).Output | Select-Object -Last 1) }
    else {
        Install-WingetPkg 'Ollama.Ollama' 'Ollama'
        Update-SessionPath
        $exe = Get-OllamaExe
        if (-not $exe) { throw 'Ollama installed but ollama.exe was not found; open a new terminal and re-run.' }
        Write-Ok 'Ollama installed.'
    }
    Set-OllamaEnvironment | Out-Null
    if (-not (Start-OllamaServer)) { throw 'Ollama server did not start. Check the log and try "ollama serve".' }
}

function Get-InstalledCline {
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $keys) {
        $hit = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'Cline*' } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Ensure-ClineCli {
    Write-Step 'Cline CLI (terminal agent)'
    $v = Get-NodeVersion
    if (-not $v -or $v.Major -lt $Script:Const.MinNodeMajor) { Ensure-Node }
    Update-SessionPath
    $cli = Get-ClineCli
    if ($cli) {
        Write-Ok ("Cline CLI present: " + ((Invoke-Native $cli @('version')).Output | Select-Object -First 1))
        if (Read-YesNo 'Update Cline CLI to the latest version?' $false) {
            [void](Invoke-Native 'npm' @('update', '-g', 'cline'))
        }
        return
    }
    if (-not (Get-ToolPath 'npm')) { throw 'npm not found. Install Node.js first (menu 2).' }
    Write-Info 'npm install -g cline ...'
    $r = Invoke-Native 'npm' @('install', '-g', 'cline')
    $r.Output | Select-Object -Last 8 | ForEach-Object { Write-Log $_ 'DEBUG' -NoConsole }
    Update-SessionPath
    if ($r.ExitCode -ne 0 -or -not (Get-ClineCli)) { throw "npm install -g cline failed (exit $($r.ExitCode)). See log." }
    Write-Ok 'Cline CLI installed. Run "cline" in any terminal.'
}

# ============================================================================
# 10. OLLAMA: ENVIRONMENT, SERVER, API
# ============================================================================
function Set-OllamaEnvironment {
    # User-level variables read by the Ollama server at start-up.
    $c = $Script:Cfg
    $vars = [ordered]@{
        OLLAMA_FLASH_ATTENTION   = '1'
        OLLAMA_KV_CACHE_TYPE     = $c.KvCache
        OLLAMA_KEEP_ALIVE        = $c.KeepAlive
        OLLAMA_NUM_PARALLEL      = '1'     # one request at a time = least memory
        OLLAMA_MAX_LOADED_MODELS = '1'
    }
    if ($c.KvCache -ne 'q8_0') { $vars.Remove('OLLAMA_KV_CACHE_TYPE') }
    $changed = $false
    foreach ($k in $vars.Keys) {
        $cur = [Environment]::GetEnvironmentVariable($k, 'User')
        if ($cur -ne $vars[$k]) {
            [Environment]::SetEnvironmentVariable($k, $vars[$k], 'User')
            $changed = $true
            Write-Info "Set $k=$($vars[$k])"
        }
        Set-Item -Path "Env:$k" -Value $vars[$k]
        $c.EnvVarsSet = @($c.EnvVarsSet + $k | Select-Object -Unique)
    }
    if ($c.KvCache -ne 'q8_0') {   # remove a stale q8_0 setting if the user switched to f16
        if ([Environment]::GetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', 'User')) {
            [Environment]::SetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', $null, 'User')
            Remove-Item Env:OLLAMA_KV_CACHE_TYPE -ErrorAction SilentlyContinue
            $changed = $true
        }
    }
    Save-Config
    if ($changed) {
        Write-Ok 'Ollama environment updated.'
        if (Test-OllamaUp) { Write-Info 'Restarting Ollama to apply it...'; [void](Start-OllamaServer -Restart) }
    }
    else { Write-Ok 'Ollama environment already configured.' }
    return $changed
}

function Invoke-OllamaApi {
    param([string]$Path, [string]$Method = 'GET', $Body = $null, [int]$TimeoutSec = 30)
    $p = @{ Uri = ($Script:Cfg.BaseUrl.TrimEnd('/') + $Path); Method = $Method; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) {
        $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress))
        $p.ContentType = 'application/json'
    }
    return Invoke-RestMethod @p
}

function Test-OllamaUp {
    try { [void](Invoke-OllamaApi '/api/version' -TimeoutSec 3); return $true } catch { return $false }
}

function Stop-Ollama {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'ollama*' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Start-OllamaServer {
    param([switch]$Restart)
    if ($Restart) { Stop-Ollama }
    if (Test-OllamaUp) { return $true }
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    $exe = Get-OllamaExe
    if (Test-Path $app) { Start-Process -FilePath $app -WindowStyle Hidden }
    elseif ($exe)       { Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden }
    else { Write-Fail 'Ollama is not installed.'; return $false }
    Write-Info 'Waiting for the Ollama API...'
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-OllamaUp) { Write-Ok "Ollama API is up at $($Script:Cfg.BaseUrl)"; return $true }
        Start-Sleep -Seconds 1
    }
    # Last resort: tray app not responding, start the server directly.
    if ($exe) {
        Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden
        for ($i = 0; $i -lt 30; $i++) { if (Test-OllamaUp) { return $true }; Start-Sleep -Seconds 1 }
    }
    return $false
}

function Test-ModelNameMatch {
    param([string]$A, [string]$B)
    return (($A.ToLower() -replace ':latest$', '') -eq ($B.ToLower() -replace ':latest$', ''))
}

function Get-InstalledModels {
    try { return @((Invoke-OllamaApi '/api/tags').models) } catch { return @() }
}

function Get-ModelInfo {
    param([string]$Name)
    $info = @{ SizeGB = 0.0; Layers = 0; MaxCtx = 0 }
    try {
        $m = Get-InstalledModels | Where-Object { Test-ModelNameMatch $_.name $Name } | Select-Object -First 1
        if ($m) { $info.SizeGB = [math]::Round($m.size / 1GB, 2) }
    } catch { }
    try {
        $show = Invoke-OllamaApi '/api/show' 'POST' @{ model = $Name; name = $Name } 60
        foreach ($p in $show.model_info.PSObject.Properties) {
            if ($p.Name -like '*.block_count')   { $info.Layers = [int]$p.Value }
            if ($p.Name -like '*.context_length') { $info.MaxCtx = [int]$p.Value }
        }
    } catch { }
    return $info
}

# Pull through the REST API so we get progress AND real error messages.
function Invoke-OllamaPull {
    param([string]$Ref)
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(12)
    try {
        $json = @{ name = $Ref; model = $Ref; stream = $true } | ConvertTo-Json -Compress
        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList @([System.Net.Http.HttpMethod]::Post, ($Script:Cfg.BaseUrl.TrimEnd('/') + '/api/pull'))
        $req.Content = New-Object System.Net.Http.StringContent -ArgumentList @($json, [Text.Encoding]::UTF8, 'application/json')
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Ollama returned HTTP $([int]$resp.StatusCode): $txt"
        }
        $reader = New-Object System.IO.StreamReader($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastStatus = ''
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line) { continue }
            $o = $line | ConvertFrom-Json
            if ($o.error) { throw "Ollama pull error: $($o.error)" }
            $status = [string]$o.status
            if ($o.total -and $o.completed -ne $null) {
                if ($sw.ElapsedMilliseconds -ge 500) {
                    $sw.Restart()
                    $pct = [math]::Round(100.0 * $o.completed / $o.total, 1)
                    Write-Host ("`r  {0,-28} {1,5}%  {2:N1} / {3:N1} GB   " -f $status.Substring(0, [math]::Min(28, $status.Length)), $pct, ($o.completed / 1GB), ($o.total / 1GB)) -NoNewline -ForegroundColor Gray
                }
            }
            elseif ($status -ne $lastStatus) {
                Write-Host ''
                Write-Host "  $status" -ForegroundColor Gray
            }
            $lastStatus = $status
        }
        Write-Host ''
    }
    finally { $client.Dispose() }
}

# ============================================================================
# 11. MODEL: SELECT, PULL, TUNE (Modelfile)
# ============================================================================
function Select-ModelSource {
    if ($Script:Unattended) {
        return @{ Ref = $Script:Const.Q5Ref; SizeGB = $Script:Const.Q5SizeGB; Key = 'q5' }
    }
    Write-Host ''
    Write-Host '  Choose a model:' -ForegroundColor White
    Write-Host ("   1) Qwen3.6 27B Q5_K_M (bartowski GGUF, ~{0} GB)  [recommended]" -f $Script:Const.Q5SizeGB)
    Write-Host ("   2) Official Ollama qwen3.6:27b (Q4_K_M, ~{0} GB)  [smaller fallback]" -f $Script:Const.OfficialSizeGB)
    Write-Host '   3) Another model - paste an Ollama pull/run command or model name'
    Write-Host '   0) Back'
    switch ((Read-Host '  Select').Trim()) {
        '1' { return @{ Ref = $Script:Const.Q5Ref;       SizeGB = $Script:Const.Q5SizeGB;       Key = 'q5' } }
        '2' { return @{ Ref = $Script:Const.OfficialRef; SizeGB = $Script:Const.OfficialSizeGB; Key = 'q4' } }
        '3' {
            $raw = Read-Host '  Model name or command (e.g. "ollama pull llama3.1:8b")'
            $t = ($raw.Trim() -replace '(?i)^ollama\s+(pull|run)\s+', '') -replace '(?i)^ollama\s+', ''
            # Only a model reference is accepted; arbitrary commands are never executed.
            if ($t -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/@\-]*$') { Write-Fail 'That does not look like a valid model reference.'; return $null }
            return @{ Ref = $t; SizeGB = 0; Key = 'custom' }
        }
        default { return $null }
    }
}

function Get-TunedName {
    param([hashtable]$Model)
    switch ($Model.Key) {
        'q5' { return 'qwen3.6-27b-q5km-cline' }
        'q4' { return 'qwen3.6-27b-q4km-cline' }
        default {
            $n = ($Model.Ref.ToLower() -replace '^hf\.co/', '' -replace '[^a-z0-9.\-]', '-').Trim('-')
            if ($n.Length -gt 60) { $n = $n.Substring(0, 60).Trim('-') }
            return "$n-cline"
        }
    }
}

function Install-Model {
    param([hashtable]$Model)
    Write-Step "Pull model: $($Model.Ref)"
    if (-not (Get-OllamaExe)) { Ensure-Ollama }
    if (-not (Start-OllamaServer)) { throw 'Ollama server is not running.' }

    $existing = Get-InstalledModels | Where-Object { Test-ModelNameMatch $_.name $Model.Ref } | Select-Object -First 1
    if ($existing) {
        Write-Ok "Already downloaded ($([math]::Round($existing.size / 1GB, 1)) GB)."
        if (-not (Read-YesNo 'Pull again to check for updates?' $false)) { return }
    }
    else {
        $blocking = Test-Requirements -ModelGB $Model.SizeGB
        if ($blocking -and -not (Read-YesNo 'Requirements check found blocking problems. Continue anyway?' $false)) { throw 'Cancelled by user.' }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Info "Downloading (attempt $attempt of 3; downloads resume automatically)..."
            Invoke-OllamaPull $Model.Ref
            Write-Ok 'Download complete.'
            break
        }
        catch {
            $msg = $_.Exception.Message
            Write-Warn $msg
            if ($msg -match 'newer version of Ollama') {
                if (Read-YesNo 'This model needs a newer Ollama. Upgrade via winget now?' $true) {
                    Install-WingetPkg 'Ollama.Ollama' 'Ollama' -Upgrade
                    [void](Start-OllamaServer -Restart)
                    continue
                }
                throw
            }
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
    $Script:Cfg.ModelRef = $Model.Ref
    Save-Config
}

# Builds a Modelfile with partial GPU offload + context, then "ollama create".
function New-TunedModel {
    param([hashtable]$Model)
    Write-Step 'Create tuned model (Modelfile)'
    [void](Start-OllamaServer)
    $info   = Get-ModelInfo $Model.Ref
    $size   = if ($info.SizeGB -gt 0) { $info.SizeGB } elseif ($Model.SizeGB -gt 0) { $Model.SizeGB } else { 20 }
    $layers = if ($info.Layers -gt 0) { $info.Layers } else { $Script:Const.DefaultLayers }
    $plan   = Get-OffloadPlan -ModelGB $size -Layers $layers -CtxSetting $Script:Cfg.ContextSize -ModelMaxCtx $info.MaxCtx

    Write-Info ("Model size ~{0} GB, {1} layers. VRAM {2} GB, RAM {3} GB." -f $size, $layers, $Script:Cfg.VramGB, $Script:Cfg.RamGB)
    Write-Info ("Plan: num_ctx={0} (KV cache ~{1} GB), GPU layers={2}/{3}, ~{4} GB in system RAM." -f
        $plan.Ctx, $plan.KvGB, $(if ($plan.NumGpu -ge 999) { 'all' } else { $plan.NumGpu }), $layers, $plan.CpuGB)
    if (-not $plan.FitsAll -and -not $Script:Cfg.OffloadToRam) {
        Write-Warn 'Offload to RAM is disabled but the model + context do not fit in VRAM.'
        if (Read-YesNo 'Enable RAM offload for this model?' $true) {
            $Script:Cfg.OffloadToRam = $true; Save-Config
            $plan = Get-OffloadPlan -ModelGB $size -Layers $layers -CtxSetting $Script:Cfg.ContextSize -ModelMaxCtx $info.MaxCtx
        }
    }
    if ($Script:Cfg.OffloadToRam -and -not $plan.FitsRam) {
        Write-Warn "Not enough free RAM for the CPU part (~$($plan.CpuGB) GB). Lower the context size or use the smaller Q4_K_M model."
    }
    if (-not $plan.FitsAll) { Write-Info 'Partial offload: expect noticeably slower generation than a model that fits fully in VRAM.' }
    if ($plan.Ctx -lt 16384) { Write-Warn 'Context below 16k is tight for Cline; consider a smaller quant or more offload.' }

    $name = Get-TunedName $Model
    $lines = @(
        "# Generated by Cline Local AI Setup $($Script:Version) on $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
        "# keep_alive is not a Modelfile setting: it comes from OLLAMA_KEEP_ALIVE ($($Script:Cfg.KeepAlive)).",
        "FROM $($Model.Ref)",
        "PARAMETER num_ctx $($plan.Ctx)"
    )
    if ($plan.NumGpu -ge 0) { $lines += "PARAMETER num_gpu $($plan.NumGpu)" }
    $lines += @('PARAMETER temperature 0.6', 'PARAMETER top_p 0.95', 'PARAMETER top_k 20')
    $mf = Join-Path $Script:ModelfileDir "$name.Modelfile"
    [IO.File]::WriteAllText($mf, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))   # no BOM
    Write-Info "Modelfile: $mf"
    $lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    $r = Invoke-Native (Get-OllamaExe) @('create', $name, '-f', $mf)
    $r.Output | ForEach-Object { Write-Log $_ 'DEBUG' -NoConsole }
    if ($r.ExitCode -ne 0) { throw "ollama create failed: $($r.Output | Select-Object -Last 3 | Out-String)" }
    Write-Ok "Created '$name'."

    $Script:Cfg.TunedName = $name
    $Script:Cfg.ModelRef = $Model.Ref
    $Script:Cfg.EffectiveCtx = $plan.Ctx
    $Script:Cfg.EffectiveGpu = $plan.NumGpu
    Save-Config
}

function Invoke-ModelWorkflow {
    param([hashtable]$Model)
    Install-Model $Model
    New-TunedModel $Model
}

# ============================================================================
# 12. CLINE EXTENSION + CONFIGURATION
# ============================================================================
function Install-ClineExtension {
    Write-Step 'Cline extension for VS Code'
    $code = Get-CodeExe
    if (-not $code) { Ensure-VSCode; $code = Get-CodeExe }
    $id = $Script:Const.ExtId
    $list = Invoke-Native $code @('--list-extensions')
    if ($list.Output -contains $id) {
        Write-Ok "$id is already installed."
        if (-not (Read-YesNo 'Reinstall/update it?' $false)) { return }
        $r = Invoke-Native $code @('--install-extension', $id, '--force')
    }
    else { $r = Invoke-Native $code @('--install-extension', $id) }
    $r.Output | ForEach-Object { Write-Log $_ 'DEBUG' -NoConsole }
    if ($r.ExitCode -ne 0) { throw "VS Code could not install $id (exit $($r.ExitCode))." }
    if ((Invoke-Native $code @('--list-extensions')).Output -contains $id) { Write-Ok "$id installed." }
    else { throw "$id does not appear in the extension list after install." }
}

function Set-ClineOllamaConfig {
    Write-Step 'Configure Cline for Ollama'
    $c = $Script:Cfg
    $base = Read-Default 'Ollama base URL' $c.BaseUrl
    if ($base -notmatch '^https?://') { throw 'Base URL must start with http:// or https://' }
    $c.BaseUrl = $base.TrimEnd('/')

    $models = @(Get-InstalledModels | ForEach-Object { $_.name })
    $default = if ($c.TunedName) { $c.TunedName } elseif ($models.Count -gt 0) { $models[0] } else { 'qwen3.6-27b-q5km-cline' }
    if ($models.Count -gt 0) { Write-Info ('Installed models: ' + ($models -join ', ')) }
    else { Write-Warn 'No models installed yet (use menu 3).' }
    $model = Read-Default 'Model name for Cline' $default
    $ctxDefault = if ($c.EffectiveCtx -gt 0) { [string]$c.EffectiveCtx } else { [string](Convert-CtxSetting $c.ContextSize) }
    if ($ctxDefault -eq '0') { $ctxDefault = '32768' }
    $ctx = Read-Number 'Context size (num_ctx) to enter in Cline' ([double]$ctxDefault) 2048 1048576
    $c.EffectiveCtx = [int]$ctx
    Save-Config

    # --- Cline CLI: configured non-interactively --------------------------------
    $cli = Get-ClineCli
    if ($cli) {
        $r = Invoke-Native $cli @('auth', '-p', 'ollama', '-m', $model, '-b', $c.BaseUrl)
        $r.Output | ForEach-Object { Write-Log $_ 'DEBUG' -NoConsole }
        if ($r.ExitCode -eq 0) { Write-Ok 'Cline CLI configured for Ollama (check with: cline config).' }
        else { Write-Warn 'cline auth failed; run "cline auth" manually or "ollama launch cline --config".' }
    }
    else { Write-Info 'Cline CLI not installed (menu 9); skipping CLI configuration.' }

    # --- VS Code extension / Desktop: values to enter in the UI -----------------
    $text = @(
        'CLINE SETTINGS FOR OLLAMA',
        '-------------------------',
        'VS Code: Cline sidebar > settings (gear) > API Configuration',
        '  API Provider ........ Ollama',
        "  Base URL ............ $($c.BaseUrl)   (tick 'Use custom base URL' if shown)",
        "  Model ............... $model",
        "  Model Context Window  $([int]$ctx)   <- must match num_ctx, Cline passes it to Ollama",
        '',
        'Alternative: API Provider "OpenAI Compatible", Base URL ' + $c.BaseUrl + '/v1, API key "ollama", Model ' + $model,
        'Cline Desktop uses the same provider/model picker (choose Ollama / local endpoint).',
        '',
        'Tips: start in Plan mode, keep auto-approve minimal (menu 7), and keep tasks small:',
        'a 27B model with partial CPU offload is slower than cloud models.'
    )
    $file = Join-Path $Script:AppDir 'cline-ollama-settings.txt'
    [IO.File]::WriteAllText($file, ($text -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Host ''
    $text | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
    try { Set-Clipboard -Value $model; Write-Ok "Model name '$model' copied to the clipboard." } catch { }
    Write-Info "Saved a copy to $file"
}

# ============================================================================
# 13. API KEYS (DPAPI-encrypted, never stored as plain text)
# ============================================================================
function ConvertTo-PlainText {
    param([securestring]$Secure)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Save-ApiKey {
    Write-Step 'Optional: store a cloud API key securely'
    Write-Host '   1) Anthropic   2) OpenAI   3) OpenRouter   0) Back'
    $sel = (Read-Host '  Select').Trim()
    $map = @{
        '1' = @{ Label = 'Anthropic';  Provider = 'anthropic';     Pattern = '^sk-ant-' }
        '2' = @{ Label = 'OpenAI';     Provider = 'openai-native'; Pattern = '^sk-' }
        '3' = @{ Label = 'OpenRouter'; Provider = 'openrouter';    Pattern = '^sk-or-' }
    }
    if (-not $map.ContainsKey($sel)) { return }
    $p = $map[$sel]
    $sec = Read-Host "Paste your $($p.Label) API key (input is hidden)" -AsSecureString
    if ($sec.Length -eq 0) { Write-Warn 'No key entered.'; return }
    $plain = ConvertTo-PlainText $sec
    if ($plain -notmatch $p.Pattern) { Write-Warn "That key does not look like a typical $($p.Label) key; stored anyway." }
    $plain = $null

    # ConvertFrom-SecureString without -Key uses Windows DPAPI: only this user on this PC can decrypt.
    $file = Join-Path $Script:SecretsDir "$($p.Provider).key"
    [IO.File]::WriteAllText($file, ($sec | ConvertFrom-SecureString), (New-Object Text.UTF8Encoding($false)))
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        [void](Invoke-Native 'icacls.exe' @($file, '/inheritance:r', '/grant:r', "${me}:(R,W)"))
    } catch { }
    Write-Ok "Stored encrypted (DPAPI) in $file"
    $Script:Cfg.ApiProviders = @($Script:Cfg.ApiProviders + $p.Provider | Select-Object -Unique)
    Save-Config

    if ((Get-ClineCli) -and (Read-YesNo 'Also apply this key to the Cline CLI now? (briefly visible in the process command line)' $false)) {
        $k = ConvertTo-PlainText ($sec)
        $r = Invoke-Native (Get-ClineCli) @('auth', '-p', $p.Provider, '-k', $k)
        $k = $null
        if ($r.ExitCode -eq 0) { Write-Ok 'Cline CLI now has this provider configured.' } else { Write-Warn 'cline auth failed.' }
    }
    if (Read-YesNo 'Copy the key to the clipboard to paste into the Cline extension/Desktop?' $false) {
        Set-Clipboard -Value (ConvertTo-PlainText $sec)
        [void](Read-Host 'Paste it now, then press Enter to clear the clipboard')
        Set-Clipboard -Value ' '
        Write-Ok 'Clipboard cleared.'
    }
    Show-SpendReminder $p.Label
}

function Show-SpendReminder {
    param([string]$Label = 'your cloud provider')
    Write-Host ''
    Write-Host '  SPEND-LIMIT REMINDER' -ForegroundColor Yellow
    Write-Host "   - Set a monthly hard limit in the $Label console before using agents (they loop and burn tokens)." -ForegroundColor Yellow
    Write-Host '   - Anthropic: Console > Limits | OpenAI: Billing > Limits | OpenRouter: set a credit limit on the key.' -ForegroundColor Yellow
    Write-Host '   - In Cline, watch the per-task cost counter and use a low "Max Requests" auto-approve cap.' -ForegroundColor Yellow
}

# ============================================================================
# 14. .clinerules + AUTO-APPROVE DEFAULTS
# ============================================================================
function Set-ClineRules {
    Write-Step 'Cline rules, auto-approve defaults, spend reminder'
    $def = if ($Script:Cfg.Workspace) { $Script:Cfg.Workspace } else { (Get-Location).Path }
    $ws = Read-Default 'Project folder to receive .clinerules' $def
    if (-not (Test-Path $ws -PathType Container)) {
        if (Read-YesNo "Folder '$ws' does not exist. Create it?" $true) { New-Item -ItemType Directory -Path $ws -Force | Out-Null }
        else { return }
    }
    $Script:Cfg.Workspace = $ws; Save-Config

    $begin = '<!-- cline-local-setup:begin -->'
    $end   = '<!-- cline-local-setup:end -->'
    $body = @(
        $begin,
        '# Rules for working with a local model (Qwen3.6 27B via Ollama)',
        '',
        '## Working style',
        '- Context is limited. Read only the files you need; never dump whole directories or huge logs.',
        '- Work in small, verifiable steps: short plan, one change, verify, repeat.',
        '- Read a file before editing it. Prefer targeted edits over rewriting whole files.',
        '- After changes, run the project build/tests/linters if they exist and fix failures before finishing.',
        '- Ask before deleting files, force-pushing, or running destructive commands.',
        '- Never print, log, or commit secrets, tokens, or .env contents.',
        '- If requirements are ambiguous, ask one concise question instead of guessing.',
        '- Keep replies short; do not restate the whole task.',
        '',
        '## Environment',
        '- The shell is PowerShell on Windows. Use PowerShell syntax and backslash paths, not bash idioms.',
        $end
    ) -join "`r`n"

    $target = Join-Path $ws '.clinerules'
    if (Test-Path $target -PathType Container) { $target = Join-Path $target '00-local-model.md' }
    $enc = New-Object Text.UTF8Encoding($false)
    if (Test-Path $target -PathType Leaf) {
        $cur = [IO.File]::ReadAllText($target)
        $rx = [regex]::new('(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end))
        if ($rx.IsMatch($cur)) { $new = $rx.Replace($cur, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $body }, 1); Write-Info 'Updating the managed block in the existing file.' }
        else { $new = $cur.TrimEnd() + "`r`n`r`n" + $body + "`r`n"; Write-Info 'Appending the managed block to the existing file.' }
    }
    else { $new = $body + "`r`n" }
    [IO.File]::WriteAllText($target, $new, $enc)
    Write-Ok "Rules written to $target"

    $aa = @(
        'RECOMMENDED CLINE AUTO-APPROVE DEFAULTS (set in the Cline panel > Auto-approve)',
        '  Read project files ............ ON   (safe, saves clicks)',
        '  Edit project files ............ OFF  at first; turn ON after you trust the model on a git-tracked repo',
        '  Execute safe commands ......... OFF  (ON only for read-only commands)',
        '  Execute all commands .......... OFF  always',
        '  Use browser / MCP servers ..... OFF',
        '  Max requests per task ......... 20 or fewer',
        'Always work on a git branch so every change can be reverted.',
        'CLI: Shift+Tab toggles auto-approve; "cline -y" auto-approves everything - avoid it on real projects.'
    )
    $file = Join-Path $Script:AppDir 'auto-approve-recommendations.txt'
    [IO.File]::WriteAllText($file, ($aa -join "`r`n"), $enc)
    Write-Host ''
    $aa | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
    Write-Info 'Cline stores auto-approve in its own settings, so these must be set once in the UI.'
    if (@($Script:Cfg.ApiProviders).Count -gt 0) { Show-SpendReminder }
    else { Write-Info 'If you later add a cloud API key, set a provider-side spend limit first (menu 6 shows how).' }
}

# ============================================================================
# 15. CONNECTION TEST
# ============================================================================
function Invoke-ConnectionTest {
    Write-Step 'Connection test'
    if (-not (Start-OllamaServer)) { throw 'Ollama API is not reachable.' }
    $v = Invoke-OllamaApi '/api/version'
    Write-Ok "Ollama API v$($v.version) at $($Script:Cfg.BaseUrl)"

    Write-Info 'ollama list:'
    $exe = Get-OllamaExe
    (Invoke-Native $exe @('list')).Output | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

    $models = @(Get-InstalledModels)
    if ($models.Count -eq 0) { throw 'No models installed. Use menu 3 first.' }
    $model = $null
    if ($Script:Cfg.TunedName) { $model = ($models | Where-Object { Test-ModelNameMatch $_.name $Script:Cfg.TunedName } | Select-Object -First 1).name }
    if (-not $model) { $model = $models[0].name }

    Write-Info "Sending a test prompt to '$model' (first load of a 27B model can take several minutes)..."
    $body = @{
        model = $model; stream = $false; keep_alive = $Script:Cfg.KeepAlive; think = $false
        messages = @(@{ role = 'user'; content = 'Reply with the single word READY, then on a new line a one-line PowerShell command that prints Hello.' })
        options = @{ num_predict = 256 }
    }
    try { $res = Invoke-OllamaApi '/api/chat' 'POST' $body 1200 }
    catch {
        Write-Log "Retrying without 'think': $($_.Exception.Message)" 'WARN' -NoConsole
        $body.Remove('think')
        $res = Invoke-OllamaApi '/api/chat' 'POST' $body 1200
    }
    Write-Ok 'Model answered:'
    ([string]$res.message.content).Trim() -split "`r?`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
    if ($res.eval_duration -gt 0) {
        Write-Info ("Speed: {0:N1} tokens/s | load time {1:N1}s | prompt tokens {2}" -f ($res.eval_count / ($res.eval_duration / 1e9)), ($res.load_duration / 1e9), $res.prompt_eval_count)
    }
    Write-Info 'ollama ps (PROCESSOR column shows the GPU/CPU split):'
    (Invoke-Native $exe @('ps')).Output | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    $smi = Get-NvidiaSmi
    if ($smi) {
        $m = Invoke-Native $smi @('--query-gpu=memory.used,memory.total', '--format=csv,noheader')
        Write-Info ("GPU memory used/total: " + ($m.Output | Select-Object -First 1))
    }
    $cli = Get-ClineCli
    if ($cli) { Write-Info ('Cline CLI: ' + ((Invoke-Native $cli @('version')).Output | Select-Object -First 1)) }
    Write-Ok 'Connection test finished.'
}

# ============================================================================
# 16. CLINE DESKTOP + SDK (+ CLI)
# ============================================================================
function Get-ClineDesktopRelease {
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/cline/cline/releases?per_page=40' `
            -Headers @{ 'User-Agent' = 'ClineLocalSetup' } -TimeoutSec 20
        $r = $rel | Where-Object { $_.tag_name -like 'desktop-v*' -and -not $_.draft } | Select-Object -First 1
        if ($r) {
            $a = $r.assets | Where-Object { $_.name -like '*x64-setup.exe' } | Select-Object -First 1
            if ($a) { return [pscustomobject]@{ Url = $a.browser_download_url; Name = $a.name; Tag = $r.tag_name } }
        }
    }
    catch { Write-Log "GitHub release lookup failed: $($_.Exception.Message)" 'WARN' -NoConsole }
    $u = $Script:Const.DesktopFallbackUrl
    return [pscustomobject]@{ Url = $u; Name = (Split-Path $u -Leaf); Tag = 'desktop-v0.0.49 (fallback)' }
}

function Install-ClineDesktop {
    Write-Step 'Cline Desktop (beta)'
    $app = Get-InstalledCline
    if ($app) {
        Write-Ok "Already installed: $($app.DisplayName) $($app.DisplayVersion)"
        if (-not (Read-YesNo 'Download and install the latest build over it?' $false)) { return }
    }
    $rel = Get-ClineDesktopRelease
    Write-Info "Latest desktop build: $($rel.Tag)"
    $dest = Join-Path $env:TEMP $rel.Name
    Write-Info "Downloading $($rel.Url)"
    Invoke-WebRequest -Uri $rel.Url -OutFile $dest -UseBasicParsing
    $hash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
    Write-Log "Downloaded $dest SHA256=$hash" 'INFO' -NoConsole
    $sig = Get-AuthenticodeSignature -FilePath $dest
    if ($sig.Status -eq 'Valid') { Write-Ok "Signed by: $($sig.SignerCertificate.Subject)" }
    else {
        Write-Warn "Installer signature status: $($sig.Status). SHA256: $hash"
        if (-not (Read-YesNo 'The installer is not validly code-signed (source: github.com/cline/cline). Install anyway?' $false)) { return }
    }
    Write-Info 'Running the installer silently (/S)...'
    $p = Start-Process -FilePath $dest -ArgumentList '/S' -Wait -PassThru
    Update-SessionPath
    if (Get-InstalledCline) { Write-Ok 'Cline Desktop installed.' }
    elseif (Read-YesNo "Silent install could not be verified (exit $($p.ExitCode)). Run the installer interactively?" $true) {
        Start-Process -FilePath $dest -Wait
        if (Get-InstalledCline) { Write-Ok 'Cline Desktop installed.' } else { Write-Warn 'Could not confirm the installation.' }
    }
    Write-Info 'In the app choose Ollama / local endpoint and use the values from menu 5.'
}

function Install-ClineSdk {
    Write-Step 'Cline SDK quickstart project'
    $v = Get-NodeVersion
    if (-not $v -or $v.Major -lt $Script:Const.MinNodeMajor) { Ensure-Node }
    if (-not (Get-ToolPath 'npm')) { throw 'npm not found. Install Node.js first.' }
    $dir = Join-Path $env:USERPROFILE 'cline-sdk-quickstart'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object Text.UTF8Encoding($false)

    $pkg = Join-Path $dir 'package.json'
    if (-not (Test-Path $pkg)) {
        $json = '{ "name": "cline-sdk-quickstart", "private": true, "type": "module", "scripts": { "start": "node agent.mjs" } }'
        [IO.File]::WriteAllText($pkg, $json, $enc)
    }
    Push-Location $dir
    try {
        Write-Info 'npm install @cline/sdk ...'
        $r = Invoke-Native 'npm' @('install', '@cline/sdk')
        $r.Output | Select-Object -Last 6 | ForEach-Object { Write-Log $_ 'DEBUG' -NoConsole }
        if ($r.ExitCode -ne 0) { throw "npm install @cline/sdk failed (exit $($r.ExitCode))." }
    }
    finally { Pop-Location }

    $agent = Join-Path $dir 'agent.mjs'
    if (Test-Path $agent) { Write-Info 'agent.mjs already exists; leaving it untouched.' }
    else {
        $model = if ($Script:Cfg.TunedName) { $Script:Cfg.TunedName } else { 'qwen3.6-27b-q5km-cline' }
        $src = @'
// Minimal Cline SDK agent that talks to your local Ollama (OpenAI-compatible endpoint).
// Docs: https://docs.cline.bot/sdk/overview   (requires Node.js 22+)
import { Agent } from "@cline/sdk"

const agent = new Agent({
  providerId: "openai-compatible",
  modelId: "__MODEL__",
  apiKey: "ollama",                      // Ollama ignores the key, but it must be non-empty
  baseUrl: "__BASE__/v1",
  maxIterations: 5,
})

agent.subscribe((event) => {
  if (event.type === "assistant-text-delta") process.stdout.write(event.text ?? "")
})

await agent.run("Explain what an SDK is in two sentences.")
console.log()
'@
        $src = $src.Replace('__MODEL__', $model).Replace('__BASE__', $Script:Cfg.BaseUrl)
        [IO.File]::WriteAllText($agent, $src, $enc)
        Write-Ok "Wrote $agent"
    }
    Write-Ok "SDK project ready: $dir  (run: cd `"$dir`"; npm start)"
}

function Install-ClineExtras {
    [void](Invoke-Tracked 'Cline CLI' { Ensure-ClineCli })
    [void](Invoke-Tracked 'Cline Desktop' { Install-ClineDesktop })
    [void](Invoke-Tracked 'Cline SDK' { Install-ClineSdk })
}

# ============================================================================
# 17. UNINSTALL / CLEANUP (every step asks first)
# ============================================================================
function Invoke-Cleanup {
    Write-Step 'Uninstall / cleanup'
    Write-Warn 'Each item asks for confirmation. Nothing is removed without a yes.'

    # Models
    if (Test-OllamaUp) {
        $models = @(Get-InstalledModels | ForEach-Object { $_.name })
        foreach ($m in $models) {
            if (Read-YesNo "Remove Ollama model '$m'?" ($m -like '*-cline*')) {
                $r = Invoke-Native (Get-OllamaExe) @('rm', $m)
                if ($r.ExitCode -eq 0) { Write-Ok "Removed $m" } else { Write-Warn "Could not remove $m" }
            }
        }
    }
    # VS Code extension
    $code = Get-CodeExe
    if ($code -and ((Invoke-Native $code @('--list-extensions')).Output -contains $Script:Const.ExtId) -and (Read-YesNo 'Uninstall the Cline VS Code extension?' $false)) {
        [void](Invoke-Native $code @('--uninstall-extension', $Script:Const.ExtId)); Write-Ok 'Extension removed.'
    }
    # CLI
    if ((Get-ClineCli) -and (Read-YesNo 'Uninstall Cline CLI (npm -g)?' $false)) {
        [void](Invoke-Native 'npm' @('uninstall', '-g', 'cline')); Write-Ok 'Cline CLI removed.'
    }
    # Desktop
    $app = Get-InstalledCline
    if ($app -and (Read-YesNo "Uninstall $($app.DisplayName)?" $false)) {
        $u = if ($app.PSObject.Properties['QuietUninstallString']) { $app.QuietUninstallString } else { $app.UninstallString }
        if ($u) {
            $exe = ($u -replace '^"([^"]+)".*$', '$1')
            if (Test-Path $exe) { Start-Process -FilePath $exe -ArgumentList '/S' -Wait; Write-Ok 'Cline Desktop uninstall started/finished.' }
            else { Write-Warn 'Uninstaller path not found; remove it from Settings > Apps.' }
        }
    }
    # SDK project
    $sdk = Join-Path $env:USERPROFILE 'cline-sdk-quickstart'
    if ((Test-Path $sdk) -and (Read-YesNo "Delete the SDK sample folder $sdk ?" $false)) { Remove-Item $sdk -Recurse -Force; Write-Ok 'SDK folder removed.' }
    # Environment variables
    if ((@($Script:Cfg.EnvVarsSet).Count -gt 0) -and (Read-YesNo ('Remove environment variables set by this script (' + ($Script:Cfg.EnvVarsSet -join ', ') + ')?') $false)) {
        foreach ($k in $Script:Cfg.EnvVarsSet) {
            [Environment]::SetEnvironmentVariable($k, $null, 'User')
            Remove-Item "Env:$k" -ErrorAction SilentlyContinue
        }
        $Script:Cfg.EnvVarsSet = @(); Save-Config; Write-Ok 'Environment variables removed (restart Ollama to apply).'
    }
    # Base apps via winget (shared tools; default NO)
    Write-Warn 'The next items are general tools you may use elsewhere.'
    $apps = @(
        @{ Id = 'Ollama.Ollama'; Name = 'Ollama' }, @{ Id = 'Microsoft.VisualStudioCode'; Name = 'VS Code' },
        @{ Id = 'OpenJS.NodeJS.LTS'; Name = 'Node.js' }, @{ Id = 'Git.Git'; Name = 'Git' }
    )
    foreach ($a in $apps) {
        if (Read-YesNo "Uninstall $($a.Name) via winget?" $false) {
            if ($a.Id -eq 'Ollama.Ollama') { Stop-Ollama }
            $r = Invoke-Native 'winget' @('uninstall', '--id', $a.Id, '-e', '--silent')
            if ($r.ExitCode -eq 0) { Write-Ok "$($a.Name) removed." } else { Write-Warn "$($a.Name): winget exit $($r.ExitCode)" }
        }
    }
    # Script data (config, encrypted keys, logs)
    if (Read-YesNo "Delete this script's data (config, encrypted API keys, Modelfiles, logs) in $($Script:AppDir)?" $false) {
        Remove-Item $Script:AppDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'Script data removed. (The log is gone too.)'
    }
}

# ============================================================================
# 18. COMPONENT SUB-MENU + FULL INSTALL
# ============================================================================
function Show-ComponentMenu {
    while ($true) {
        Write-Host ''
        Write-Host '  Install / repair components' -ForegroundColor White
        Write-Host '   1) NVIDIA driver check     5) Ollama (+ env tuning)'
        Write-Host '   2) Git                     6) Cline CLI (terminal)'
        Write-Host '   3) Node.js 22+             7) All of the above'
        Write-Host '   4) VS Code 1.84+           0) Back'
        switch ((Read-Host '  Select').Trim()) {
            '1' { [void](Invoke-Step 'NVIDIA driver' { Ensure-NvidiaDriver }) }
            '2' { [void](Invoke-Step 'Git' { Ensure-Git }) }
            '3' { [void](Invoke-Step 'Node.js' { Ensure-Node }) }
            '4' { [void](Invoke-Step 'VS Code' { Ensure-VSCode }) }
            '5' { [void](Invoke-Step 'Ollama' { Ensure-Ollama }) }
            '6' { [void](Invoke-Step 'Cline CLI' { Ensure-ClineCli }) }
            '7' {
                foreach ($s in @(
                        @{ N = 'NVIDIA driver'; A = { Ensure-NvidiaDriver } }, @{ N = 'Git'; A = { Ensure-Git } },
                        @{ N = 'Node.js'; A = { Ensure-Node } }, @{ N = 'VS Code'; A = { Ensure-VSCode } },
                        @{ N = 'Ollama'; A = { Ensure-Ollama } }, @{ N = 'Cline CLI'; A = { Ensure-ClineCli } })) {
                    [void](Invoke-Step $s.N $s.A)
                }
            }
            '0' { return }
            default { Write-Warn 'Invalid choice.' }
        }
    }
}

function Invoke-FullInstall {
    $Script:Results.Clear()
    Write-Step 'Full automatic install'
    Initialize-Hardware
    $model = Select-ModelSource
    if (-not $model) { Write-Info 'Cancelled.'; return }

    $blocking = Test-Requirements -ModelGB $model.SizeGB
    if ($blocking -and -not (Read-YesNo 'Blocking problems were found. Continue anyway?' $false)) { return }

    [void](Invoke-Tracked 'NVIDIA driver check' { Ensure-NvidiaDriver })
    [void](Invoke-Tracked 'Git'                  { Ensure-Git })
    [void](Invoke-Tracked 'Node.js'              { Ensure-Node })
    [void](Invoke-Tracked 'VS Code'              { Ensure-VSCode })
    [void](Invoke-Tracked 'Ollama'               { Ensure-Ollama })
    [void](Invoke-Tracked 'Model download + Modelfile' { Invoke-ModelWorkflow $model })
    [void](Invoke-Tracked 'Cline extension'      { Install-ClineExtension })
    [void](Invoke-Tracked 'Cline CLI'            { Ensure-ClineCli })
    if (Read-YesNo 'Install Cline Desktop (beta) and the SDK sample too?' $true) {
        [void](Invoke-Tracked 'Cline Desktop' { Install-ClineDesktop })
        [void](Invoke-Tracked 'Cline SDK'     { Install-ClineSdk })
    }
    [void](Invoke-Tracked 'Configure Cline for Ollama' { Set-ClineOllamaConfig })
    if (Read-YesNo 'Create a .clinerules file for a project now?' $false) { [void](Invoke-Tracked 'Cline rules' { Set-ClineRules }) }
    [void](Invoke-Tracked 'Connection test' { Invoke-ConnectionTest })

    Write-Step 'Summary'
    $Script:Results | Format-Table -AutoSize | Out-Host
    $failed = @($Script:Results | Where-Object { $_.Status -ne 'OK' }).Count
    if ($failed -eq 0) { Write-Ok 'Everything completed. Open VS Code, click the Cline icon, and enter the values shown above.' }
    else { Write-Warn "$failed step(s) failed. Fix the cause (see the log) and re-run: finished steps are skipped." }
    Write-Info "Log file: $($Script:LogFile)"
}

# ============================================================================
# 19. MAIN MENU
# ============================================================================
function Show-Banner {
    $c = $Script:Cfg
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host "  Cline + Ollama Local AI Coding Setup   v$($Script:Version)" -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor Cyan
    if ($c.GpuName) {
        Write-Host ("  GPU: {0} ({1} GB) | RAM: {2} GB | RAM offload: {3} | ctx: {4}" -f
            $c.GpuName, $c.VramGB, $c.RamGB, $(if ($c.OffloadToRam) { 'yes' } else { 'no' }), $c.ContextSize) -ForegroundColor Gray
    }
    else { Write-Host '  Hardware profile not set yet (it is asked on first use; H to edit).' -ForegroundColor DarkGray }
    if ($c.TunedName) { Write-Host "  Model: $($c.TunedName)  (ctx $($c.EffectiveCtx))" -ForegroundColor Gray }
    if (@($c.ApiProviders).Count -gt 0) { Write-Host '  Reminder: you stored a cloud API key - keep a provider-side spend limit set.' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '   1  Run full automatic install'
    Write-Host '   2  Install/repair individual components'
    Write-Host '   3  Pull model (Q5_K_M / fallback / your own)'
    Write-Host '   4  Install Cline extension (saoudrizwan.claude-dev)'
    Write-Host '   5  Configure Cline for Ollama'
    Write-Host '   6  Optional: store an API key securely'
    Write-Host '   7  Optional: .clinerules, auto-approve, spend limit'
    Write-Host '   8  Test connection (ollama list + test prompt)'
    Write-Host '   9  Install Cline Desktop, SDK and CLI'
    Write-Host '  10  Uninstall / cleanup'
    Write-Host '   H  Hardware and optimization profile'
    Write-Host '   0  Exit'
}

function Show-MainMenu {
    while ($true) {
        Show-Banner
        $choice = (Read-Host "`nSelect an option").Trim().ToUpper()
        switch ($choice) {
            '1'  { [void](Invoke-Step 'Full automatic install' { Invoke-FullInstall }); Wait-Enter }
            '2'  { Show-ComponentMenu }
            '3'  {
                [void](Invoke-Step 'Pull model' {
                    Initialize-Hardware
                    $m = Select-ModelSource
                    if ($m) { Invoke-ModelWorkflow $m }
                }); Wait-Enter
            }
            '4'  { [void](Invoke-Step 'Cline extension' { Install-ClineExtension }); Wait-Enter }
            '5'  { [void](Invoke-Step 'Configure Cline' { Set-ClineOllamaConfig }); Wait-Enter }
            '6'  { [void](Invoke-Step 'API key' { Save-ApiKey }); Wait-Enter }
            '7'  { [void](Invoke-Step 'Cline rules' { Set-ClineRules }); Wait-Enter }
            '8'  { [void](Invoke-Step 'Connection test' { Invoke-ConnectionTest }); Wait-Enter }
            '9'  { [void](Invoke-Step 'Cline Desktop/SDK/CLI' { Install-ClineExtras }); Wait-Enter }
            '10' { [void](Invoke-Step 'Cleanup' { Invoke-Cleanup }); Wait-Enter }
            'H'  {
                [void](Invoke-Step 'Hardware profile' {
                    Initialize-Hardware -Force
                    Set-OllamaEnvironment | Out-Null
                    if ($Script:Cfg.ModelRef) { Write-Info 'Re-run menu 3 (or 1) to rebuild the tuned model with the new settings.' }
                }); Wait-Enter
            }
            '0'  { return }
            default { Write-Warn 'Invalid choice.' }
        }
    }
}

# ============================================================================
# 20. ENTRY POINT
# ============================================================================
try {
    Import-Config
    Update-SessionPath
    Write-Log "Session start v$($Script:Version) user=$env:USERNAME admin=$(Test-IsAdmin) unattended=$($Script:Unattended)" 'INFO' -NoConsole
    if ($Script:Unattended) { [void](Invoke-Step 'Full automatic install' { Invoke-FullInstall }) }
    else { Show-MainMenu }
}
catch {
    Write-Fail "Fatal error: $($_.Exception.Message)"
    Write-Log ($_ | Out-String) 'ERROR' -NoConsole
    if (-not $Script:Unattended) { [void](Read-Host 'Press Enter to close') }
    exit 1
}
finally {
    Write-Log 'Session end' 'INFO' -NoConsole
}
Write-Host "`nBye. Log: $($Script:LogFile)" -ForegroundColor Cyan
