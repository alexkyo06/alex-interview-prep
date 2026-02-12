# VPS隧道一键设置脚本
# 保存为: tunnel-setup.ps1
# 运行: 右键以管理员身份运行，或PowerShell中执行: .\tunnel-setup.ps1

param(
    [switch]$Force = $false
)

# 脚本信息
$ScriptVersion = "1.0"
$VpsHost = "204.152.193.127"
$LogFile = "$env:USERPROFILE\Documents\tunnel-setup-log.txt"
$ScriptStartTime = Get-Date

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    $logMessage | Out-File -FilePath $LogFile -Append -Encoding UTF8
    Write-Host $logMessage -ForegroundColor $(if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARNING") { "Yellow" } else { "White" })
}

function Test-Admin {
    $currentUser = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 开始
Write-Log "=== VPS隧道一键设置脚本 v$ScriptVersion ==="
Write-Log "开始时间: $ScriptStartTime"
Write-Log "VPS主机: $VpsHost"

# 检查管理员权限
if (-not (Test-Admin)) {
    Write-Log "需要管理员权限运行此脚本！" -Level "ERROR"
    Write-Host "`n请右键点击PowerShell，选择'以管理员身份运行'，然后再次执行此脚本。" -ForegroundColor Red
    Write-Host "或者按 Ctrl+R 输入: powershell -Command `"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""$PSScriptRoot\tunnel-setup.ps1""'`"" -ForegroundColor Yellow
    pause
    exit 1
}
Write-Log "管理员权限确认" -Level "INFO"

# 1. 停止现有SSH进程
Write-Log "步骤1: 停止现有SSH隧道进程"
$sshProcesses = Get-Process ssh -ErrorAction SilentlyContinue
if ($sshProcesses) {
    Write-Log "找到 $($sshProcesses.Count) 个SSH进程，正在停止..."
    $sshProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Log "SSH进程已停止"
} else {
    Write-Log "未找到运行的SSH进程"
}

# 2. 创建SSH优化配置
Write-Log "步骤2: 创建SSH优化配置"
$sshConfigPath = "$env:USERPROFILE\.ssh\config"
$sshConfigDir = Split-Path $sshConfigPath -Parent
if (-not (Test-Path $sshConfigDir)) {
    New-Item -ItemType Directory -Path $sshConfigDir -Force | Out-Null
    Write-Log "创建SSH配置目录: $sshConfigDir"
}

$sshConfigContent = @"
# VPS隧道优化配置
Host vps-tunnel
    HostName $VpsHost
    User root
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ConnectTimeout 60
    # 如果是首次连接，需要输入密码: alexkyo
    
Host vps-tunnel-test
    HostName $VpsHost
    User root
    Port 22
"@

if (-not (Test-Path $sshConfigPath) -or $Force) {
    $sshConfigContent | Out-File -FilePath $sshConfigPath -Encoding UTF8
    Write-Log "SSH配置已创建/更新: $sshConfigPath"
} else {
    Write-Log "SSH配置已存在，跳过创建（使用 -Force 参数覆盖）" -Level "WARNING"
}

# 3. 测试VPS连接
Write-Log "步骤3: 测试VPS连接"
try {
    $connection = Test-NetConnection -ComputerName $VpsHost -Port 22 -WarningAction SilentlyContinue -ErrorAction Stop
    if ($connection.TcpTestSucceeded) {
        Write-Log "✅ VPS连接测试成功: $VpsHost:22" -Level "INFO"
    } else {
        Write-Log "❌ VPS连接测试失败" -Level "ERROR"
    }
} catch {
    Write-Log "⚠️ VPS连接测试异常: $_" -Level "WARNING"
}

# 4. 创建守护脚本
Write-Log "步骤4: 创建隧道守护脚本"
$keeperScript = @"
# VPS隧道守护脚本
# 自动维护与VPS的SSH隧道连接

`$logFile = "`$env:USERPROFILE\Documents\tunnel-keeper-log.txt"
`$vpsHost = "$VpsHost"

function Write-KeeperLog {
    param([string]`$Message)
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "`[`$timestamp`] `$Message" | Out-File -FilePath `$logFile -Append
}

Write-KeeperLog "=== 隧道守护脚本启动 ==="

# 主守护循环
while (`$true) {
    try {
        # 检查VPS连接
        `$connection = Test-NetConnection -ComputerName `$vpsHost -Port 22 -WarningAction SilentlyContinue
        
        if (`$connection.TcpTestSucceeded) {
            Write-KeeperLog "✅ 连接正常（60秒后再次检查）"
            Start-Sleep -Seconds 60
        } else {
            Write-KeeperLog "❌ 连接断开，正在重建隧道..."
            
            # 停止可能残留的SSH进程
            Get-Process ssh -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            
            # 建立新隧道（后台运行）
            Start-Process powershell -ArgumentList @"
-WindowStyle Hidden -Command `"ssh vps-tunnel -R 2222:localhost:22 -R 3389:localhost:3389 -R 5900:localhost:5900 -N -f`"
"@ -WindowStyle Hidden
            
            Write-KeeperLog "✅ 隧道重建完成"
            Start-Sleep -Seconds 15
        }
    } catch {
        Write-KeeperLog "⚠️ 检查失败: `$_"
        Start-Sleep -Seconds 30
    }
}
"@

$keeperScriptPath = "$env:USERPROFILE\Documents\Keep-Tunnel.ps1"
$keeperScript | Out-File -FilePath $keeperScriptPath -Encoding UTF8
Write-Log "守护脚本已创建: $keeperScriptPath"

# 5. 创建计划任务
Write-Log "步骤5: 创建计划任务（开机自启）"
$taskName = "VPS-Tunnel-Keeper"
$taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($taskExists -and -not $Force) {
    Write-Log "计划任务已存在，跳过创建（使用 -Force 参数覆盖）" -Level "WARNING"
} else {
    if ($taskExists -and $Force) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "已删除现有计划任务" -Level "INFO"
    }
    
    try {
        # 创建触发器（开机启动 + 每5分钟检查）
        $trigger1 = New-ScheduledTaskTrigger -AtStartup
        $trigger2 = New-ScheduledTaskTrigger -Daily -At "12:00AM" -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
        
        # 设置操作
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$keeperScriptPath`""
        
        # 设置权限
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        
        # 任务设置
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -RestartCount 3
        
        # 注册任务
        Register-ScheduledTask -TaskName $taskName `
            -Trigger $trigger1, $trigger2 `
            -Action $action `
            -Principal $principal `
            -Settings $settings `
            -Description "保持VPS SSH隧道连接（2222/3389/5900端口）" `
            -Force
        
        Write-Log "✅ 计划任务创建成功: $taskName" -Level "INFO"
        
        # 立即启动任务测试
        Start-ScheduledTask -TaskName $taskName
        Write-Log "计划任务已启动" -Level "INFO"
        
    } catch {
        Write-Log "❌ 计划任务创建失败: $_" -Level "ERROR"
    }
}

# 6. 优化电源设置（可选）
Write-Log "步骤6: 优化电源设置（防止休眠断开）"
try {
    powercfg -change -standby-timeout-ac 0 2>$null
    powercfg -change -hibernate-timeout-ac 0 2>$null
    Write-Log "电源设置优化完成（禁用休眠）" -Level "INFO"
} catch {
    Write-Log "⚠️ 电源设置优化失败（非必需）" -Level "WARNING"
}

# 7. 测试当前连接
Write-Log "步骤7: 测试当前隧道连接"
Write-Host "`n正在建立初始隧道连接..." -ForegroundColor Cyan
Write-Host "首次连接需要输入密码: alexkyo" -ForegroundColor Yellow
Write-Host "如果密码错误，请按 Ctrl+C 中断，然后手动输入正确密码" -ForegroundColor Yellow

try {
    # 启动隧道（前台运行，以便输入密码）
    Start-Process powershell -ArgumentList @"
-WindowStyle Normal -Command `"ssh vps-tunnel -R 2222:localhost:22 -R 3389:localhost:3389 -R 5900:localhost:5900 -N`"
"@ -NoNewWindow
    
    Write-Log "隧道启动命令已执行" -Level "INFO"
    Write-Host "`n✅ 隧道已启动！请保持此窗口打开或最小化。" -ForegroundColor Green
    Write-Host "✅ 守护脚本将在后台监控连接状态" -ForegroundColor Green
    Write-Host "✅ 电脑重启后将自动恢复连接" -ForegroundColor Green
    
} catch {
    Write-Log "❌ 隧道启动失败: $_" -Level "ERROR"
    Write-Host "`n⚠️ 隧道启动失败，请手动执行以下命令：" -ForegroundColor Yellow
    Write-Host "ssh vps-tunnel -R 2222:localhost:22 -R 3389:localhost:3389 -R 5900:localhost:5900" -ForegroundColor White
}

# 完成
$scriptEndTime = Get-Date
$duration = $scriptEndTime - $ScriptStartTime
Write-Log "=== 脚本执行完成 ==="
Write-Log "总耗时: $($duration.TotalSeconds.ToString('0.00')) 秒"
Write-Log "日志文件: $LogFile"
Write-Log "守护脚本: $keeperScriptPath"
Write-Log "计划任务: $taskName"

Write-Host "`n" + "="*50
Write-Host "🎉 设置完成！" -ForegroundColor Green
Write-Host "="*50
Write-Host "`n📋 设置摘要：" -ForegroundColor Cyan
Write-Host "  ✅ SSH优化配置: $sshConfigPath"
Write-Host "  ✅ 守护脚本: $keeperScriptPath"
Write-Host "  ✅ 计划任务: $taskName (开机自启)"
Write-Host "  ✅ 电源优化: 已禁用休眠"
Write-Host "  ✅ 当前隧道: 已启动（如需密码请手动输入）"
Write-Host "`n📁 日志文件: $LogFile"
Write-Host "`n🔧 验证命令：" -ForegroundColor Yellow
Write-Host "  检查任务状态: Get-ScheduledTask -TaskName `"$taskName`""
Write-Host "  查看守护日志: Get-Content `"$env:USERPROFILE\Documents\tunnel-keeper-log.txt`" -Tail 10"
Write-Host "  测试VPS连接: Test-NetConnection -ComputerName $VpsHost -Port 22"
Write-Host "`n⚠️  注意：" -ForegroundColor Yellow
Write-Host "  1. 首次连接需要输入SSH密码"
Write-Host "  2. 保持当前窗口运行或最小化"
Write-Host "  3. 重启电脑测试自动恢复"
Write-Host "`n按任意键查看详细指南..." -ForegroundColor Gray
pause

# 显示指南
Write-Host "`n🌐 详细指南：" -ForegroundColor Cyan
Write-Host "  网页指南: http://localhost:8080/tunnel-guide.html" -ForegroundColor White
Write-Host "  GitHub仓库: https://github.com/alexkyo06/alex-interview-prep" -ForegroundColor White
Write-Host "`n📞 如有问题，通过Telegram联系小爪助手" -ForegroundColor Gray