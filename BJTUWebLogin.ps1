<#
SPDX-License-Identifier: MIT
Copyright (c) 2026 launcherray
Project: https://github.com/launcherray/bjtu-campus-net-auto-auth
Maintainer: https://github.com/launcherray

个人维护的非官方校园网自动认证脚本，使用 AI 辅助编写。
接口来源为普通用户可访问的校园网登录页面及其浏览器请求。
不包含校方未公开的内部私有接口、服务端源码、内部文档或敏感代码。
完整项目声明、隐私说明与许可条款见 README.md、SECURITY.md 和 LICENSE。
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Check', 'Run', 'Window')]
    [string]$Action = 'Menu'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$runStarted = [DateTime]::UtcNow
$portal = 'https://login.bjtu.edu.cn'
$api = "${portal}:802/eportal/portal/"
$taskName = 'BJTU Web Login'
$windowTaskName = 'BJTU Web Login Window'
$sourceDir = $PSScriptRoot
$installDir = Join-Path $env:ProgramFiles 'BJTUWebLogin'
$installedScript = Join-Path $installDir 'BJTUWebLogin.ps1'
$privateDir = Join-Path $installDir 'private'
$credentialPath = Join-Path $privateDir 'credential.bin'
$logPath = Join-Path $installDir 'last-run.log'
$stopPath = Join-Path $installDir 'stop.request'
$windowsPowerShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-PortalClient {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(7)
    return $client
}

function Invoke-PortalRequest($Client, [string]$Endpoint, $Fields) {
    $Fields.jsVersion = '4.2.1'
    $Fields.lang = 'zh'
    $Fields.v = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $query = foreach ($key in $Fields.Keys) {
        [uri]::EscapeDataString($key) + '=' + [uri]::EscapeDataString([string]$Fields[$key])
    }
    $url = $Endpoint + '?callback=bjtuLogin&' + ($query -join '&')
    $body = $Client.GetStringAsync($url).GetAwaiter().GetResult()
    if ($body -match '(?s)^\s*bjtuLogin\s*\(\s*(\{.*\})\s*\)\s*;?\s*$') {
        $body = $Matches[1]
    }
    return ConvertFrom-Json -InputObject $body
}

function Get-PortalStatus($Client) {
    $response = Invoke-PortalRequest $Client "$portal/drcom/chkstatus" @{}
    if ([string]$response.result -notin '0', '1') {
        throw 'Unexpected status response'
    }
    return $response
}

function Get-LoginFields($Client, $Status) {
    # 与认证页的 term.init 一样，使用网关报告的终端地址。
    $clientIp = $null
    foreach ($candidate in @($Status.v46ip, $Status.ss5, $Status.v4ip)) {
        $parsedIp = $null
        if ([Net.IPAddress]::TryParse([string]$candidate, [ref]$parsedIp) -and
            $parsedIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            $parsedIp -ne [Net.IPAddress]::Any) {
            $clientIp = $parsedIp.ToString()
            break
        }
    }
    if (-not $clientIp) {
        throw 'No client address from portal'
    }

    $config = Invoke-PortalRequest $Client "${api}page/loadConfig" @{
        program_index = ''
        wlan_vlan_id = 1
        wlan_user_ip = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($clientIp))
        wlan_user_ipv6 = ''
        wlan_user_ssid = ''
        wlan_user_areaid = ''
        wlan_ac_ip = ''
        wlan_ap_mac = '000000000000'
        gw_id = '000000000000'
    }
    # 遇到验证码或认证方式改变时，交由用户在网页上完成。
    if ([string]$config.data.login_method -ne '1' -or
        $config.data.check_online_method -notin $null, 0, '0', '' -or
        $config.data.account_prefix -notin $null, 0, '0', '' -or
        $config.data.password_cut -notin $null, 0, '0', '' -or
        $config.hidm -notin $null, 0, '0', '' -or
        $config.data.hidm -notin $null, 0, '0', '') {
        throw 'Unsupported portal configuration'
    }

    $mac = [string]$Status.ss4 -replace '[-:]', ''
    if ($mac -notmatch '^[0-9a-fA-F]{12}$') {
        $mac = '000000000000'
    }
    return @{
        login_method = 1
        wlan_user_ip = $clientIp
        wlan_user_ipv6 = ''
        wlan_user_mac = $mac
        wlan_ac_ip = ''
        wlan_ac_name = ''
        terminal_type = 1
    }
}

function Read-PortalCredential {
    Add-Type -AssemblyName System.Security
    $protectedBytes = [IO.File]::ReadAllBytes($credentialPath)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    try {
        return ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($bytes))
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Complete-Run([int]$Code, [string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss zzz}  {1}' -f (Get-Date), $Message
    try {
        Set-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
        Write-Host '无法更新运行记录。'
    }
    Write-Host $Message
    return $Code
}

function Wait-ForRetry([int]$Seconds) {
    while ($Seconds -gt 0) {
        if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
            return $false
        }
        $interval = [Math]::Min(5, $Seconds)
        Start-Sleep -Seconds $interval
        $Seconds -= $interval
    }
    return -not (Test-Path -LiteralPath $stopPath -PathType Leaf)
}

function Invoke-LoginAttempt([int]$MaxStatusAttempts) {
    $client = New-PortalClient
    try {
        $status = $null
        for ($attempt = 1; $attempt -le $MaxStatusAttempts; $attempt++) {
            if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
                return @{ Code = 9; Message = '已按用户要求停止认证。' }
            }
            $null = Complete-Run 0 "正在查询校园网认证状态（第 $attempt/$MaxStatusAttempts 次）。"
            try {
                $status = Get-PortalStatus $client
                break
            } catch {
                if ($attempt -lt $MaxStatusAttempts) {
                    $nextAttempt = (Get-Date).AddSeconds(20).ToString('yyyy-MM-dd HH:mm:ss zzz')
                    $null = Complete-Run 2 "本次状态查询失败。将于 $nextAttempt 再次查询。"
                    if (-not (Wait-ForRetry 20)) {
                        return @{ Code = 9; Message = '已按用户要求停止认证。' }
                    }
                }
            }
        }
        if ($null -eq $status) {
            return @{ Code = 2; Message = '未能确认校园网状态。' }
        }
        if ([string]$status.result -eq '1') {
            return @{ Code = 0; Message = '校园网已认证，跳过登录。' }
        }

        try {
            $fields = Get-LoginFields $client $status
        } catch {
            return @{ Code = 3; Message = '无法确认门户登录参数，请打开校园网网页手动认证。' }
        }
        try {
            $credential = Read-PortalCredential
        } catch {
            return @{ Code = 4; Message = '无法读取本机凭据，请在管理菜单重新设置。' }
        }

        if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
            return @{ Code = 9; Message = '已按用户要求停止认证。' }
        }
        $fields.user_account = $credential.username
        $fields.user_password = $credential.password
        $null = Complete-Run 0 '正在提交认证请求。'
        $rejected = $false
        try {
            $response = Invoke-PortalRequest $client "${api}login" $fields
            $rejected = [string]$response.result -eq '0'
        } catch {
            # 请求超时后仍检查是否已上线，避免重复提交。
        } finally {
            $fields.Remove('user_password')
            $credential = $null
        }

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if (-not (Wait-ForRetry 2)) {
                return @{ Code = 9; Message = '已按用户要求停止认证。' }
            }
            try {
                $status = Get-PortalStatus $client
                if ([string]$status.result -eq '1') {
                    return @{ Code = 0; Message = '校园网自动认证成功。' }
                }
            } catch {
                # 下次检查可覆盖网关短暂不可用的情况。
            }
        }
        if ($rejected) {
            return @{ Code = 5; Message = '门户未接受认证。请核对账号、运营商和密码，或在网页手动认证。' }
        }
        return @{ Code = 5; Message = '提交后未能确认已上线。请在网页查看认证状态。' }
    } finally {
        $client.Dispose()
    }
}

function Invoke-LoginRun {
    $statusAttempts = 18
    $null = Complete-Run 0 '正在检查校园网认证状态。'
    while ($true) {
        try {
            $result = Invoke-LoginAttempt $statusAttempts
        } catch {
            $result = @{ Code = 8; Message = '本次检查或认证出错。' }
        }
        if ($result.Code -in 0, 9) {
            return Complete-Run $result.Code $result.Message
        }
        $nextAttempt = (Get-Date).AddHours(1).ToString('yyyy-MM-dd HH:mm:ss zzz')
        $null = Complete-Run $result.Code ($result.Message + " 将于 $nextAttempt 再次检查并尝试认证。")
        if (-not (Wait-ForRetry 3600)) {
            return Complete-Run 9 '已按用户要求停止认证。'
        }
        $statusAttempts = 1
    }
}

function Write-LocalFile([string]$Path, [byte[]]$Bytes) {
    $tempPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($tempPath, $Bytes)
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($tempPath, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($tempPath, $Path)
        }
    } finally {
        [IO.File]::Delete($tempPath)
    }
}

function Update-InstalledScript {
    if ($PSCommandPath -ne $installedScript) {
        Write-LocalFile $installedScript ([IO.File]::ReadAllBytes($PSCommandPath))
    }
}

function Set-PortalCredential {
    Write-Host '请输入校园网账号。使用校园电信或校园联通时，附加网页选项对应的后缀，例如 @dx 或 @lt。'
    $username = (Read-Host '校园网账号').Trim()
    if (-not $username) {
        Write-Host '账号为空，已取消。'
        return
    }
    $password = Read-Host '校园网密码（隐藏输入）' -AsSecureString
    if ($password.Length -eq 0) {
        Write-Host '密码为空，已取消。'
        return
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Update-InstalledScript
    New-Item -ItemType Directory -Path $privateDir -Force | Out-Null
    $acl = Get-Acl -LiteralPath $privateDir
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $privateDir -AclObject $acl

    Add-Type -AssemblyName System.Security
    $networkCredential = [Net.NetworkCredential]::new($username, $password)
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{
        username = $username
        password = $networkCredential.Password
    } | ConvertTo-Json -Compress))
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        Write-LocalFile $credentialPath $protectedBytes
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $password.Dispose()
    }
    Write-Host '已将账号密码加密保存在本机。'
}

function Enable-BootLogin {
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        Write-Host '请先选择 1 设置校园网账号和密码。'
        return
    }
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run' -f $installedScript
    $jobAction = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument $arguments -WorkingDirectory $installDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT15S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $windowArguments = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Window' -f $installedScript
    $windowAction = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument $windowArguments -WorkingDirectory $installDir
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $windowTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userSid
    $windowTrigger.Delay = 'PT20S'
    $windowPrincipal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Highest
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $runLock = Disable-BootLogin $task
    try {
        Update-InstalledScript
        Register-ScheduledTask -TaskName $windowTaskName -Action $windowAction -Trigger $windowTrigger `
            -Principal $windowPrincipal -Settings $settings -Description 'Show the BJTU authentication status window after Windows sign-in.' -Force | Out-Null
        Register-ScheduledTask -TaskName $taskName -Action $jobAction -Trigger $trigger `
            -Principal $principal -Settings $settings -Description 'Check BJTU campus network at system startup.' -Force | Out-Null
    } finally {
        if ($runLock) { $runLock.Dispose() }
    }
    Write-Host '开机自启已开启。'
}

function Open-RunLock([switch]$RemoveOnClose) {
    $options = if ($RemoveOnClose) { [IO.FileOptions]::DeleteOnClose } else { [IO.FileOptions]::None }
    return [IO.FileStream]::new(
        (Join-Path $installDir 'run.lock'), [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, $options
    )
}

function Disable-BootLogin($Task) {
    if ($Task -and $Task.Settings.Enabled) {
        Disable-ScheduledTask -InputObject $Task | Out-Null
    }
    $windowTask = Get-ScheduledTask -TaskName $windowTaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($windowTask) {
        if ($windowTask.Settings.Enabled) {
            Disable-ScheduledTask -InputObject $windowTask | Out-Null
        }
        if ($windowTask.State -eq 'Running') {
            Stop-ScheduledTask -InputObject $windowTask | Out-Null
        }
    }
    if ([IO.Directory]::Exists($installDir)) {
        $dir = Get-Item -LiteralPath $installDir -Force
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw '安装目录不是普通文件夹，请检查安装位置。'
        }
        [IO.File]::WriteAllText($stopPath, '')
    }
    if ($Task -and $Task.State -eq 'Running') {
        Stop-ScheduledTask -InputObject $Task | Out-Null
    }
    if (-not [IO.Directory]::Exists($installDir)) {
        return
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $runLock = Open-RunLock -RemoveOnClose
        } catch [IO.IOException] {
            Start-Sleep -Seconds 1
            continue
        }
        try {
            [IO.File]::Delete($stopPath)
            return $runLock
        } catch {
            $runLock.Dispose()
            throw
        }
    }
    throw '停止请求已发出，认证脚本尚未退出，请稍后重试。'
}

function Remove-LocalFileAndTemps([string]$Path) {
    $dir = Split-Path -LiteralPath $Path
    if (-not [IO.Directory]::Exists($dir)) {
        return
    }
    [IO.File]::Delete($Path)
    $pattern = '^{0}\.[0-9a-f]{{32}}\.tmp$' -f [regex]::Escape([IO.Path]::GetFileName($Path))
    foreach ($file in (Get-ChildItem -LiteralPath $dir -File -Force)) {
        if ($file.Name -match $pattern) {
            [IO.File]::Delete($file.FullName)
        }
    }
}

function Remove-EmptyProgramDirectory([string]$Path) {
    if ([IO.Directory]::Exists($Path)) {
        if (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1) {
            Write-Host "已保留含其他文件的目录 $Path"
        } else {
            [IO.Directory]::Delete($Path)
        }
    }
}

function Invoke-ProgramCleanup([switch]$Uninstall) {
    # 只清理本程序目录里的指定文件，不沿目录链接清理。
    foreach ($path in @($installDir, $privateDir)) {
        if (Test-Path -LiteralPath $path) {
            $dir = Get-Item -LiteralPath $path -Force
            if (-not $dir.PSIsContainer -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "安装目录不是普通文件夹，请检查 $path"
            }
        }
    }

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') {
            throw
        }
    }
    $runLock = Disable-BootLogin $task
    try {
        if ($Uninstall -and $task) {
            Unregister-ScheduledTask -InputObject $task -Confirm:$false | Out-Null
        }
        if ($Uninstall) {
            $windowTask = Get-ScheduledTask -TaskName $windowTaskName -TaskPath '\' -ErrorAction SilentlyContinue
            if ($windowTask) {
                Unregister-ScheduledTask -InputObject $windowTask -Confirm:$false | Out-Null
            }
        }
        Remove-LocalFileAndTemps $credentialPath
        if ($Uninstall -and $runLock) {
            Remove-LocalFileAndTemps $installedScript
            [IO.File]::Delete($logPath)
            Remove-EmptyProgramDirectory $privateDir
        }
    } finally {
        if ($runLock) {
            $runLock.Dispose()
        }
    }
    if ($Uninstall) {
        Remove-EmptyProgramDirectory $installDir
    }
}

function Clear-SavedCredential {
    if ((Read-Host '将关闭开机自启并清除保存的账号密码。输入 Y 确认') -ne 'Y') {
        Write-Host '已取消。'
        return
    }
    Invoke-ProgramCleanup
    Write-Host '已清除保存的账号密码，开机自启已关闭。'
}

function Uninstall-Program {
    $sourceScript = Join-Path $sourceDir 'BJTUWebLogin.ps1'
    if ($PSCommandPath -ne $sourceScript -or $sourceDir -eq $installDir) {
        throw '请从原目录双击 Manage.cmd 再执行卸载。'
    }
    Write-Host '卸载会删除开机任务、加密凭据、日志和程序文件。'
    Write-Host "程序原目录 $sourceDir"
    Write-Host "安装目录 $installDir"
    Write-Host '保存的网页和其他文件会保留。'
    if ((Read-Host '确认 1/3 是否卸载本程序？输入 Y 继续') -ne 'Y' -or
        (Read-Host '确认 2/3 是否清除保存的凭据和运行记录？输入 Y 继续') -ne 'Y' -or
        (Read-Host '确认 3/3 输入 UNINSTALL 执行卸载') -cne 'UNINSTALL') {
        Write-Host '已取消卸载。'
        return $false
    }

    Invoke-ProgramCleanup -Uninstall
    $guide = Join-Path $sourceDir '使用说明.md'
    if ((Test-Path -LiteralPath $guide -PathType Leaf) -and
        (Get-Content -LiteralPath $guide -Encoding UTF8 -TotalCount 1) -eq '# 北京交通大学校园网自动认证') {
        [IO.File]::Delete($guide)
    }
    $launcher = Join-Path $sourceDir 'Manage.cmd'
    if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and
        (Select-String -LiteralPath $launcher -SimpleMatch '-File "%~dp0BJTUWebLogin.ps1" -Action Menu' -Quiet)) {
        [IO.File]::Delete($launcher)
    }
    [IO.File]::Delete($sourceScript)
    Write-Host '卸载完成。按 Enter 关闭窗口。'
    $null = Read-Host
    return $true
}

function Show-PortalStatus {
    $client = New-PortalClient
    try {
        $status = Get-PortalStatus $client
        if ([string]$status.result -eq '1') {
            Write-Host '校园网已认证。'
        } else {
            Write-Host '校园网未认证。'
        }
        return 0
    } catch {
        Write-Host '无法确认校园网状态。'
        return 2
    } finally {
        $client.Dispose()
    }
}

function Test-RunIsActive([string]$LockPath) {
    if (-not [IO.File]::Exists($LockPath)) { return $false }
    try {
        $probe = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $probe.Dispose()
        return $false
    } catch [IO.IOException] {
        # 仅共享冲突表示有运行实例，文件被删除等其他情况表示已退出。
        return ($_.Exception.GetBaseException().HResult -band 0xFFFF) -in 32, 33
    }
}

function New-RunWindow([string]$LockPath, [string]$LogPath, [string]$StopPath) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    $form.Text = '北京交通大学校园网自动认证'
    $form.ClientSize = [Drawing.Size]::new(600, 270)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
    $form.AutoScaleMode = 'Font'

    $heading = [Windows.Forms.Label]::new()
    $heading.Text = '校园网认证正在运行'
    $heading.Location = [Drawing.Point]::new(22, 20)
    $heading.Size = [Drawing.Size]::new(556, 30)
    $heading.Font = [Drawing.Font]::new('Microsoft YaHei UI', 13, [Drawing.FontStyle]::Bold)
    $status = [Windows.Forms.Label]::new()
    $status.Text = '正在读取认证状态……'
    $status.Location = [Drawing.Point]::new(22, 64)
    $status.Size = [Drawing.Size]::new(556, 94)
    $countdown = [Windows.Forms.Label]::new()
    $countdown.Location = [Drawing.Point]::new(22, 164)
    $countdown.Size = [Drawing.Size]::new(556, 27)
    $hint = [Windows.Forms.Label]::new()
    $hint.Text = '关闭窗口将停止本次运行，下次开机按自启设置运行。'
    $hint.Location = [Drawing.Point]::new(22, 208)
    $hint.Size = [Drawing.Size]::new(370, 48)
    $stop = [Windows.Forms.Button]::new()
    $stop.Text = '停止并退出'
    $stop.Location = [Drawing.Point]::new(422, 209)
    $stop.Size = [Drawing.Size]::new(156, 37)
    $form.Controls.AddRange(@($heading, $status, $countdown, $hint, $stop))

    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $view = @{
        Form = $form; Status = $status; Countdown = $countdown; Stop = $stop
        LockPath = $LockPath; LogPath = $LogPath; StopPath = $StopPath
        AllowClose = $false; Stopping = $false; Timer = $timer
        IsActive = ${function:Test-RunIsActive}
    }
    $requestStop = {
        if ($view.Stopping) { return }
        try {
            [IO.File]::WriteAllText($view.StopPath, '')
            $view.Stopping = $true
            $view.Stop.Enabled = $false
            $view.Status.Text = '正在停止认证，请稍候……'
            $view.Countdown.Text = ''
        } catch {
            $view.Status.Text = '无法发送停止请求，请使用管理菜单中的“关闭开机自启”。'
        }
    }.GetNewClosure()
    $refresh = {
        if (-not (& $view.IsActive $view.LockPath)) {
            $view.AllowClose = $true
            $view.Form.Close()
            return
        }
        if ($view.Stopping) { return }
        try {
            $line = [IO.File]::ReadAllText($view.LogPath).Trim()
            $view.Status.Text = $line
            $view.Countdown.Text = ''
            if ($line -match '将于 (.*?) 再次') {
                $next = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($Matches[1], [ref]$next)) {
                    $remaining = $next - [DateTimeOffset]::Now
                    if ($remaining.TotalSeconds -gt 0) {
                        $view.Countdown.Text = '下次重试倒计时  {0:00} 分 {1:00} 秒' -f [Math]::Floor($remaining.TotalMinutes), $remaining.Seconds
                    } else {
                        $view.Countdown.Text = '即将重新检查认证状态……'
                    }
                }
            }
        } catch {
            # 日志正在更新时保留上一帧，下一秒继续读取。
        }
    }.GetNewClosure()
    $stop.Add_Click($requestStop)
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $view.AllowClose -and (& $view.IsActive $view.LockPath)) {
            $eventArgs.Cancel = $true
            & $requestStop
        }
    }.GetNewClosure())
    $form.Add_Shown({
        & $refresh
        if (-not $view.AllowClose) { $view.Timer.Start() }
    }.GetNewClosure())
    $form.Add_FormClosed({ $view.Timer.Stop(); $view.Timer.Dispose() }.GetNewClosure())
    $timer.Add_Tick($refresh)
    $view.Refresh = $refresh
    $form.Tag = $view
    return $form
}

function Show-RunWindow {
    $created = $false
    $mutex = [Threading.Mutex]::new($true, 'Local\BJTUWebLoginWindow', [ref]$created)
    if (-not $created) { $mutex.Dispose(); return }
    try {
        $lockPath = Join-Path $installDir 'run.lock'
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (Test-RunIsActive $lockPath) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-RunIsActive $lockPath)) { return }
        $form = New-RunWindow $lockPath $logPath $stopPath
        try { $null = $form.ShowDialog() } finally { $form.Dispose() }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Show-Menu {
    do {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        $state = if ($task -and $task.Settings.Enabled) { '开启' } else { '关闭' }
        Write-Host ""
        Write-Host "北京交通大学校园网自动认证    开机自启：$state"
        Write-Host '1  设置或更新校园网账号和密码'
        Write-Host '2  开启开机自启'
        Write-Host '3  关闭开机自启'
        Write-Host '4  立即运行一次'
        Write-Host '5  检查当前认证状态'
        Write-Host '6  查看上次运行结果'
        Write-Host '7  清除保存的账号密码并关闭开机自启'
        Write-Host '8  卸载程序'
        Write-Host '0  退出'
        $choice = Read-Host '请选择'
        try {
            switch ($choice) {
                '1' { Set-PortalCredential }
                '2' { Enable-BootLogin }
                '3' {
                    $runLock = Disable-BootLogin $task
                    if ($runLock) { $runLock.Dispose() }
                    Write-Host '开机自启已关闭，正在运行的认证脚本已停止。'
                }
                '4' {
                    if (Test-Path -LiteralPath $installedScript -PathType Leaf) {
                        Update-InstalledScript
                        $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run' -f $installedScript
                        Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -WindowStyle Hidden
                        $windowArguments = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Window' -f $installedScript
                        Start-Process -FilePath $windowsPowerShell -ArgumentList $windowArguments -WindowStyle Hidden
                        Write-Host '已启动认证脚本和状态窗口，可在状态窗口停止本次运行。'
                    } else {
                        Write-Host '请先选择 1 设置校园网账号和密码。'
                    }
                }
                '5' { $null = Show-PortalStatus }
                '6' {
                    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                        Get-Content -LiteralPath $logPath -Encoding UTF8
                    } else {
                        Write-Host '还没有运行记录。'
                    }
                }
                '7' { Clear-SavedCredential }
                '8' {
                    if (Uninstall-Program) {
                        return
                    }
                }
            }
        } catch {
            if ($choice -in '7', '8') {
                Write-Host "清理未完成。$($_.Exception.Message)"
            } else {
                Write-Host '操作失败。请确认已授予管理员权限，并检查 Windows 任务计划程序是否可用。'
            }
        }
    } until ($choice -eq '0')
}

switch ($Action) {
    'Check' { exit (Show-PortalStatus) }
    'Window' { Show-RunWindow }
    'Run' {
        if ($PSCommandPath -ne $installedScript) {
            Write-Host '请从管理菜单运行已安装的副本。'
            exit 6
        }
        try {
            $runLock = Open-RunLock
        } catch [IO.IOException] {
            Write-Host '已有运行实例，或暂时无法打开运行锁。'
            exit 7
        }
        try {
            if ([IO.File]::Exists($stopPath) -and [IO.File]::GetLastWriteTimeUtc($stopPath) -lt $runStarted) {
                [IO.File]::Delete($stopPath)
            }
            exit (Invoke-LoginRun)
        } catch {
            exit (Complete-Run 8 '运行出错。请在管理菜单重新运行，或在网页手动认证。')
        } finally {
            try { [IO.File]::Delete($stopPath) } finally { $runLock.Dispose() }
        }
    }
    'Menu' {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Menu' -f $PSCommandPath
            Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs
            exit
        }
        Show-Menu
    }
}
