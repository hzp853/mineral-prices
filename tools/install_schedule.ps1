# =============================================================================
#  install_schedule.ps1 —— 在本机注册一个"每个工作日 18:10 自动抓数"的计划任务
#
#  用法（一般不需要管理员权限）：
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_schedule.ps1
#    ... -Time 17:30          # 改成别的时间
#    ... -Uninstall           # 删除这个计划任务
#    ... -Status              # 只看当前状态
#
#  说明：任务只是每天调用 update_data.ps1 更新 data/ 下的 JSON。
#  本机开着、浏览器在用的就是本地文件；如果站点托管在 GitHub Pages，
#  推荐用仓库里的 .github/workflows/update.yml（不依赖本机开机）。
# =============================================================================
param(
  [string]$Time = '18:10',
  [switch]$Uninstall,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
$TaskName = 'MinePricesUpdate'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Script = Join-Path $Root 'tools\update_data.ps1'

function Show-Status {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) { Write-Host "未注册计划任务 $TaskName"; return }
  $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
  Write-Host ("任务：" + $t.TaskName + "  状态：" + $t.State)
  if ($info) {
    Write-Host ("上次运行：" + $info.LastRunTime + "  结果：" + $info.LastTaskResult + "  下次运行：" + $info.NextRunTime)
  }
}

if ($Status) { Show-Status; return }

if ($Uninstall) {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($t) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "已删除计划任务 $TaskName" }
  else { Write-Host "没有找到 $TaskName，无需删除" }
  return
}

if (-not (Test-Path $Script)) { throw "找不到 $Script" }

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Script + '" -Quiet'
$action = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $Root
# 周一到周五，每天 -Time 触发
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description '矿产品价格中枢：每个工作日抓取交易所行情并更新 site/data' -Force | Out-Null

Write-Host ("已注册计划任务：$TaskName（每周一至周五 " + $Time + " 运行）")
Write-Host ("脚本：" + $Script)
Show-Status
