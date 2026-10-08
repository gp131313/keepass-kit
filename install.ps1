#Requires -Version 5.1
# install.ps1 — KeePass Kit: KeePass 2.x, плагины и настройки за один запуск.
# Windows PowerShell 5.1+, от администратора. Запускается из KeePass-Kit-Setup.exe (файлы распакованы в -Dir)
# или через Install.cmd из папки репозитория: тогда недостающие файлы скачиваются по kit.json.
# Всё скачанное сверяется с SHA256 из kit.json, установщик KeePass — ещё и с подписью автора.
# Повторный запуск безопасен: меняется только то, что расходится с kit.json.
# Журнал: %ProgramData%\KeePassKit\install.log
param(
  [string]$Dir = $PSScriptRoot,
  [switch]$Silent,
  [switch]$NoFinishBox,
  [switch]$DryRun,        # только показать, что изменилось бы; права администратора не нужны
  [switch]$UserOnly,      # только настройки текущего пользователя (конфиг, автозапуск), без прав администратора
  [switch]$WithWinHello,  # ставить KeePassWinHello и без сканера отпечатков или камеры
  [switch]$NoWinHello,
  [switch]$NoGuard,       # не трогать службу Windows ssh-agent и не ставить сторожа
  [switch]$NoStart,       # не запускать KeePass в конце
  [string]$FetchOnly      # для build.ps1: скачать и проверить все файлы в эту папку и выйти
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$LogDir = Join-Path $env:ProgramData 'KeePassKit'
$Log = Join-Path $LogDir 'install.log'
$Work = Join-Path $env:TEMP ('KeePassKit-' + $PID)
$WriteLog = -not ($DryRun -or $FetchOnly)

function L([string]$m) {
  $s = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m
  [Console]::Out.WriteLine($s)
  if ($WriteLog) { Add-Content -Path $Log -Value $s -Encoding UTF8 }
}

function Test-Hash([string]$Path, [string]$Sha) {
  (Test-Path -LiteralPath $Path) -and ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha.ToUpperInvariant())
}

# Проверка отзыва сертификата — «по возможности»: за VPN сервер отзыва бывает недоступен
# (CRYPT_E_REVOCATION_OFFLINE), а подлинность файла и так проверяется по SHA256 из kit.json.
function Get-Url([string]$Url, [string]$Out) {
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (Test-Path $curl) {
    & $curl -sL --fail --retry 3 --ssl-revoke-best-effort -o $Out $Url
    if ($LASTEXITCODE -eq 0) { return }
    L "curl: код $LASTEXITCODE, пробую Invoke-WebRequest"
  }
  try { Invoke-WebRequest $Url -OutFile $Out -UseBasicParsing }
  catch { throw "Не удалось скачать: $Url ($($_.Exception.Message))" }
}

# Файл из kit.json: сначала рядом со скриптом (распакован из exe), иначе скачать — напрямую или из zip
function Get-Payload($Item) {
  if ($FetchOnly) { $cached = Join-Path $FetchOnly $Item.file; if (Test-Hash $cached $Item.sha256) { return $cached } }
  $local = Join-Path $Dir $Item.file
  if (Test-Hash $local $Item.sha256) { return $local }
  if (Test-Path -LiteralPath $local) { throw "$($Item.file): SHA256 не совпадает с kit.json" }
  New-Item -ItemType Directory -Force $Work | Out-Null
  $name = if ($Item.archive) { $Item.archive } else { $Item.file }
  $dl = Join-Path $Work $name
  if (-not (Test-Path -LiteralPath $dl)) { L ("скачиваю " + $Item.url); Get-Url $Item.url $dl }
  if ($Item.archive) {
    if (-not (Test-Hash $dl $Item.archiveSha256)) { throw "$($Item.archive): SHA256 не совпадает с kit.json" }
    $x = Join-Path $Work ($Item.name + '-unzip')
    if (Test-Path $x) { Remove-Item $x -Recurse -Force }
    Expand-Archive -LiteralPath $dl -DestinationPath $x
    $f = Get-ChildItem $x -Recurse -File -Filter $Item.file | Select-Object -First 1
    if (-not $f) { throw "$($Item.file) не найден в $($Item.archive)" }
    $dl = $f.FullName
  }
  if (-not (Test-Hash $dl $Item.sha256)) { throw "$($Item.file): SHA256 не совпадает с kit.json" }
  return $dl
}

function Test-KeePassSignature([string]$Path) {
  $s = Get-AuthenticodeSignature -LiteralPath $Path
  if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch [regex]::Escape($kit.keepass.signer)) {
    throw "Подпись $(Split-Path $Path -Leaf) не прошла проверку: $($s.Status) $($s.SignerCertificate.Subject)"
  }
}

function Find-KeePass {
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KeePassPasswordSafe2_is1',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\KeePassPasswordSafe2_is1') {
    $loc = (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallLocation
    if ($loc) { $e = Join-Path $loc 'KeePass.exe'; if (Test-Path $e) { return $e } }
  }
  foreach ($e in "$env:ProgramFiles\KeePass Password Safe 2\KeePass.exe", "${env:ProgramFiles(x86)}\KeePass Password Safe 2\KeePass.exe") {
    if (Test-Path $e) { return $e }
  }
  return $null
}

function Get-FileVersion3([string]$Path) {
  $v = (Get-Item -LiteralPath $Path).VersionInfo
  [version]('{0}.{1}.{2}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart)
}

function Test-Biometric {
  @(Get-PnpDevice -Class Biometric -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
}

function Test-WantPlugin($P) {
  if ($P.when -eq 'biometric') {
    if ($NoWinHello) { return $false }
    if ($WithWinHello) { return $true }
    return (Test-Biometric)
  }
  return $true
}

function Get-PluginPlan([string]$PluginDir) {
  $ops = @()
  foreach ($n in $kit.removePlugins) {
    $f = Join-Path $PluginDir $n
    if (Test-Path -LiteralPath $f) { $ops += [pscustomobject]@{ Op = 'remove'; File = $n; Item = $null } }
  }
  foreach ($p in $kit.plugins) {
    if (-not (Test-WantPlugin $p)) { continue }
    if (-not (Test-Hash (Join-Path $PluginDir $p.file) $p.sha256)) { $ops += [pscustomobject]@{ Op = 'install'; File = $p.file; Item = $p } }
  }
  $ops
}

function Stop-KeePass([string]$Exe) {
  if (-not (Get-Process KeePass -ErrorAction SilentlyContinue)) { return }
  L 'KeePass запущен — закрываю его (KeePass.exe --exit-all)'
  & $Exe --exit-all
  for ($i = 0; $i -lt 60 -and (Get-Process KeePass -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
  if (Get-Process KeePass -ErrorAction SilentlyContinue) {
    throw 'KeePass не закрылся (возможно, ждёт ответа о несохранённых изменениях). Закройте его через «Файл → Выход» и запустите установку снова.'
  }
}

# ---- конфиг пользователя %APPDATA%\KeePass\KeePass.config.xml ----
function Set-ConfigValue([xml]$X, [string]$Path, [string]$Value) {
  $node = $X.DocumentElement
  foreach ($part in $Path.Split('/')) {
    $c = $node.SelectSingleNode($part)
    if (-not $c) { $c = $X.CreateElement($part); [void]$node.AppendChild($c) }
    $node = $c
  }
  if ($node.InnerText -ne $Value) { $node.InnerText = $Value; return $true }
  return $false
}

function Set-CustomItem([xml]$X, [string]$Key, [string]$Value) {
  $custom = $X.DocumentElement.SelectSingleNode('Custom')
  if (-not $custom) { $custom = $X.CreateElement('Custom'); [void]$X.DocumentElement.AppendChild($custom) }
  $item = $null
  foreach ($i in $custom.SelectNodes('Item')) { $k = $i.SelectSingleNode('Key'); if ($k -and $k.InnerText -eq $Key) { $item = $i; break } }
  if (-not $item) {
    $item = $X.CreateElement('Item')
    $k = $X.CreateElement('Key'); $k.InnerText = $Key; [void]$item.AppendChild($k)
    [void]$custom.AppendChild($item)
  }
  $v = $item.SelectSingleNode('Value')
  if (-not $v) { $v = $X.CreateElement('Value'); [void]$item.AppendChild($v) }
  if ($v.InnerText -ne $Value) { $v.InnerText = $Value; return $true }
  return $false
}

function Find-DropboxDb {
  $info = Join-Path $env:LOCALAPPDATA 'Dropbox\info.json'
  if (-not (Test-Path $info)) { return }
  $j = Get-Content $info -Raw -Encoding UTF8 | ConvertFrom-Json
  $roots = @($j.personal.path, $j.business.path) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  foreach ($r in $roots) {
    Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -File -Filter '*.kdbx' -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch 'conflicted|конфликт|копия' }
  }
}

# Возвращает список изменений; с -Apply записывает файл (старый — в .kit-backup)
function Update-Config([string]$KpExe, [bool]$Apply) {
  $cfg = Join-Path $env:APPDATA 'KeePass\KeePass.config.xml'
  $x = New-Object Xml.XmlDocument
  if (Test-Path -LiteralPath $cfg) { $x.Load($cfg) }
  else { $x.LoadXml('<?xml version="1.0" encoding="utf-8"?><Configuration xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" />') }
  $out = @()
  foreach ($s in $kit.settings) { if (Set-ConfigValue $x $s.path ([string]$s.value)) { $out += "настройка $($s.path) = $($s.value)" } }
  foreach ($p in $kit.custom.PSObject.Properties) { if (Set-CustomItem $x $p.Name ([string]$p.Value)) { $out += "настройка $($p.Name) = $($p.Value)" } }

  $lu = $x.DocumentElement.SelectSingleNode('Application/LastUsedFile/Path')
  $luPath = if ($lu) { $lu.InnerText } else { '' }
  if ($luPath -and -not [IO.Path]::IsPathRooted($luPath) -and $KpExe) { $luPath = Join-Path (Split-Path $KpExe) $luPath }
  if (-not $luPath -or -not (Test-Path -LiteralPath $luPath)) {
    $db = @(Find-DropboxDb)
    if ($db.Count -eq 1) {
      [void](Set-ConfigValue $x 'Application/LastUsedFile/Path' $db[0].FullName)
      $out += "последняя база: $($db[0].FullName)"
    } elseif ($Apply) {
    } elseif ($db.Count -gt 1) {
      L ('в Dropbox несколько баз (' + (($db | ForEach-Object Name) -join ', ') + ') — при первом запуске откройте нужную сами')
    } else {
      L 'база в папке Dropbox не найдена — при первом запуске откройте её сами'
    }
  }

  if ($Apply -and $out) {
    New-Item -ItemType Directory -Force (Split-Path $cfg) | Out-Null
    if (Test-Path -LiteralPath $cfg) { Copy-Item -LiteralPath $cfg ($cfg + '.kit-backup') -Force }
    $ws = New-Object Xml.XmlWriterSettings
    $ws.Indent = $true; $ws.IndentChars = "`t"; $ws.Encoding = New-Object Text.UTF8Encoding($false)
    $w = [Xml.XmlWriter]::Create($cfg, $ws)
    try { $x.Save($w) } finally { $w.Close() }
  }
  $out
}

# ---- сторож службы ssh-agent (тот же, что в навыке keepass-ssh-agent-setup) ----
$GuardText = @'
# guard.ps1 - installed by Install-SshAgentGuard.ps1. Keeps Windows ssh-agent Stopped/Disabled for KeeAgent.
$ErrorActionPreference = 'SilentlyContinue'
$s = Get-Service ssh-agent
if (-not $s) { exit 0 }
if ($s.Status -eq 'Stopped' -and $s.StartType -eq 'Disabled') { exit 0 }
$before = '{0}/{1}' -f $s.Status, $s.StartType
Set-Service ssh-agent -StartupType Disabled
Stop-Service ssh-agent -Force
Start-Sleep -Seconds 2
$s = Get-Service ssh-agent
$after = '{0}/{1}' -f $s.Status, $s.StartType
Add-Content -Path 'C:\ClaudeScripts\sshagent-guard\guard.log' -Value ('{0:yyyy-MM-dd HH:mm:ss} ssh-agent {1} -> {2}' -f (Get-Date), $before, $after)
if (Get-Process KeePass) {
  & "$env:SystemRoot\System32\msg.exe" * /TIME:3600 'Служба Windows ssh-agent снова была включена (вероятно, установка или обновление OpenSSH), сторож её остановил и отключил. Чтобы KeeAgent занял канал SSH-агента, перезапустите KeePass: Файл -> Выход и запустите снова.'
}
'@

function Install-Guard {
  $gd = $kit.sshAgentGuard.dir
  $guard = Join-Path $gd 'guard.ps1'
  $glog = Join-Path $gd 'install.log'
  [IO.Directory]::CreateDirectory($gd) | Out-Null
  $text = $GuardText.Replace('C:\ClaudeScripts\sshagent-guard', $gd)
  [IO.File]::WriteAllText($guard, $text, (New-Object Text.UTF8Encoding($true)))
  & icacls.exe $gd /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
  & icacls.exe "$gd\*" /reset /T /C | Out-Null
  & icacls.exe $gd /setowner '*S-1-5-32-544' /T /C | Out-Null
  $esc = { param($t) [Security.SecurityElement]::Escape($t) }
  $q7040 = "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[Provider[@Name='Service Control Manager'] and EventID=7040]] and *[EventData[Data[@Name='param4']='ssh-agent']]</Select></Query></QueryList>"
  $q7045 = "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[Provider[@Name='Service Control Manager'] and EventID=7045]] and *[EventData[Data[@Name='ServiceName']='OpenSSH Authentication Agent']]</Select></Query></QueryList>"
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>KeePass Kit</Author>
    <Description>Keeps the Windows ssh-agent service Stopped/Disabled so that KeeAgent (KeePass) owns the openssh-ssh-agent pipe. Triggers: boot; 1 min after SCM 7040 (ssh-agent start type changed) or 7045 (service installed). Script: $guard. Log: $gd\guard.log</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT1M</Delay><Subscription>$(& $esc $q7040)</Subscription></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT1M</Delay><Subscription>$(& $esc $q7045)</Subscription></EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$guard"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  Register-ScheduledTask -TaskName $kit.sshAgentGuard.task -Xml $xml -Force | Out-Null
  Add-Content -Path $glog -Value ('{0:yyyy-MM-dd HH:mm:ss} installed by KeePass Kit on {1}, guard.ps1 sha256 {2}' -f (Get-Date), $env:COMPUTERNAME, (Get-FileHash $guard).Hash) -Encoding UTF8
}

function Get-ShellUser {
  $sid = (Get-Process -Id $PID).SessionId
  $e = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sid" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $e) { return $null }
  $o = Invoke-CimMethod -InputObject $e -MethodName GetOwner
  if ($o.User) { return ('{0}\{1}' -f $o.Domain, $o.User) }
  return $null
}

# ================================ main ================================
$exitCode = 0
try {
  $kit = Get-Content (Join-Path $Dir 'kit.json') -Raw -Encoding UTF8 | ConvertFrom-Json

  if ($FetchOnly) {
    New-Item -ItemType Directory -Force $FetchOnly | Out-Null
    foreach ($item in @($kit.keepass) + @($kit.plugins)) {
      $p = Get-Payload $item
      $dst = Join-Path $FetchOnly $item.file
      if ($p -ne $dst) { Copy-Item -LiteralPath $p $dst -Force }
      L ("ok  {0}  sha256 {1}" -f $item.file, $item.sha256)
    }
    Test-KeePassSignature (Join-Path $FetchOnly $kit.keepass.file)
    L ('ok  подпись ' + $kit.keepass.file)
    exit 0
  }

  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin -and -not $DryRun -and -not $UserOnly) { throw 'Нужны права администратора: запустите KeePass-Kit-Setup.exe или Install.cmd.' }
  if ($WriteLog) { New-Item -ItemType Directory -Force $LogDir | Out-Null }

  $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $shellUser = Get-ShellUser
  $userPart = (-not $shellUser) -or ($shellUser -eq $me)
  L ("=== KeePass Kit на {0}: {1}{2} ===" -f $env:COMPUTERNAME, $me, $(if ($DryRun) { ', пробный запуск' } elseif ($UserOnly) { ', только настройки пользователя' } else { '' }))
  if (-not $userPart) { L "в Windows вошёл $shellUser, а установщик работает от $me — настройки пользователя пропускаю (потом: install.ps1 -UserOnly от своей учётной записи)" }

  # ---------- план ----------
  $plan = New-Object System.Collections.Generic.List[string]
  $kpExe = Find-KeePass
  $want = [version]$kit.keepass.version
  $have = if ($kpExe) { Get-FileVersion3 $kpExe } else { $null }
  L ('KeePass: ' + $(if ($kpExe) { "$have ($kpExe)" } else { 'не установлен' }) + ", нужен не ниже $want")
  $needSetup = (-not $UserOnly) -and ((-not $have) -or ($have -lt $want))
  if ($needSetup) { $plan.Add("установить KeePass $($kit.keepass.version)") }

  $kpDir = if ($kpExe) { Split-Path $kpExe } else { "$env:ProgramFiles\KeePass Password Safe 2" }
  $pluginOps = @()
  if (-not $UserOnly) {
    $pluginOps = @(Get-PluginPlan (Join-Path $kpDir 'Plugins'))
    foreach ($o in $pluginOps) { $plan.Add($(if ($o.Op -eq 'remove') { "удалить плагин $($o.File)" } else { "поставить плагин $($o.Item.name) $($o.Item.version)" })) }
    if (-not (Test-WantPlugin ($kit.plugins | Where-Object { $_.when -eq 'biometric' } | Select-Object -First 1))) { L 'KeePassWinHello пропускаю: нет сканера отпечатков или камеры Windows Hello (поставить всё равно: -WithWinHello)' }
  }

  $cfgPlan = @()
  $autostartFix = $false
  if ($userPart) {
    $cfgPlan = @(Update-Config $kpExe $false)
    foreach ($c in $cfgPlan) { $plan.Add($c) }
    if ($kit.autostart) {
      $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
      $runWant = '"' + (Join-Path $kpDir 'KeePass.exe') + '"'
      $runHave = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'KeePass Password Safe 2'
      if ($runHave -ne $runWant) { $autostartFix = $true; $plan.Add('автозапуск KeePass вместе с Windows') }
    }
  }

  $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
  $guardFix = $false; $svcFix = $false
  if ($svc -and -not $UserOnly -and -not $NoGuard) {
    $persisted = @(Get-ChildItem 'HKCU:\Software\OpenSSH\Agent\Keys' -ErrorAction SilentlyContinue).Count
    if ($persisted -gt 0) {
      L "в агенте Windows сохранены ключи ($persisted) — службу ssh-agent не трогаю; если она не нужна, отключите её и запустите установку снова"
    } else {
      $guardFix = -not (Test-Path (Join-Path $kit.sshAgentGuard.dir 'guard.ps1'))
      $svcFix = -not ($svc.Status -eq 'Stopped' -and $svc.StartType -eq 'Disabled')
      if ($guardFix) { $plan.Add('сторож службы ssh-agent (задача Планировщика от SYSTEM)') }
      if ($svcFix) { $plan.Add("служба ssh-agent: $($svc.Status)/$($svc.StartType) -> Stopped/Disabled") }
    }
  }

  if ($DryRun) {
    if ($plan.Count) { foreach ($p in $plan) { L "[dry-run] $p" } } else { L '[dry-run] всё уже в нужном состоянии' }
    exit 0
  }
  if (-not $plan.Count) {
    L '=== ИТОГ ==='
    L 'Всё уже установлено и настроено, менять нечего.'
    exit 0
  }

  # ---------- выполнение ----------
  $wasRunning = [bool](Get-Process KeePass -ErrorAction SilentlyContinue)
  if ($wasRunning) { Stop-KeePass $kpExe }

  if ($needSetup) {
    $setup = Get-Payload $kit.keepass
    Test-KeePassSignature $setup
    L "ставлю KeePass $($kit.keepass.version)"
    $p = Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="{0}"' -f (Join-Path $LogDir 'keepass-setup.log')) -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Установщик KeePass завершился с кодом $($p.ExitCode), журнал: $LogDir\keepass-setup.log" }
    $kpExe = Find-KeePass
    if (-not $kpExe) { throw 'После установки KeePass.exe не найден' }
    $kpDir = Split-Path $kpExe
    L ("KeePass установлен: {0} ({1})" -f (Get-FileVersion3 $kpExe), $kpExe)
    $pluginOps = @(Get-PluginPlan (Join-Path $kpDir 'Plugins'))
  }

  if ($pluginOps) {
    $pd = Join-Path $kpDir 'Plugins'
    New-Item -ItemType Directory -Force $pd | Out-Null
    foreach ($o in $pluginOps) {
      $dst = Join-Path $pd $o.File
      if ($o.Op -eq 'remove') { Remove-Item -LiteralPath $dst -Force; L "плагин удалён: $($o.File)" }
      else { Copy-Item -LiteralPath (Get-Payload $o.Item) $dst -Force; L "плагин установлен: $($o.Item.name) $($o.Item.version)" }
    }
    # скомпилированные .plgx пересоберутся при запуске KeePass; старые копии не нужны
    if ($userPart) { Remove-Item (Join-Path $env:LOCALAPPDATA 'KeePass\PluginCache') -Recurse -Force -ErrorAction SilentlyContinue }
  }

  if ($userPart) {
    foreach ($c in @(Update-Config $kpExe $true)) { L $c }
    if ($autostartFix) {
      Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'KeePass Password Safe 2' -Value ('"' + $kpExe + '"')
      L 'автозапуск KeePass включён'
    }
  }

  if ($guardFix) { Install-Guard; L ('сторож ssh-agent установлен: ' + $kit.sshAgentGuard.dir) }
  if ($svcFix) {
    Set-Service ssh-agent -StartupType Disabled
    Stop-Service ssh-agent -Force
    L ('служба ssh-agent: ' + (Get-Service ssh-agent).Status + '/' + (Get-Service ssh-agent).StartType)
  }

  if ($userPart -and -not $NoStart -and $kpExe) {
    # через explorer — KeePass запустится без прав администратора, как обычно
    Start-Process (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"' + $kpExe + '"')
    L 'KeePass запущен'
  }

  L '=== ИТОГ ==='
  foreach ($p in $plan) { L ('• ' + $p) }
  $hello = $pluginOps | Where-Object { $_.Item -and $_.Item.name -eq 'KeePassWinHello' }
  if ($hello) { L 'Вход по отпечатку заработает после первого открытия базы мастер-паролем.' }
} catch {
  L ('ОШИБКА: ' + $_.Exception.Message)
  [Console]::Error.WriteLine($_.Exception.Message)
  $exitCode = 1
} finally {
  if (Test-Path $Work) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
