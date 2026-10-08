@echo off
rem PowerShell 7 module path must not leak into Windows PowerShell 5.1
set "PSModulePath="
rem KeePass Kit: двойной клик по этому файлу для установки из папки репозитория. Запросит права администратора один раз.
rem Недостающие файлы (установщик KeePass, плагины) install.ps1 скачает сам и сверит с kit.json.
rem Ключи передаются в install.ps1, например: Install.cmd -NoWinHello -DryRun
set "KPK_DIR=%~dp0"
set "KPK_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d = $env:KPK_DIR.TrimEnd('\'); $a = '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"' + $d + '\install.ps1\" ' + $env:KPK_ARGS; try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a -ErrorAction Stop } catch { Write-Host 'Administrator rights are required - setup cancelled.' -ForegroundColor Red; pause }"
