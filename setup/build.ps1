# build.ps1 — сборка KeePass-Kit-Setup.exe компилятором C# из состава Windows (.NET Framework 4.x), SDK не нужен.
# Скачивает закреплённые в kit.json файлы в setup\payload (SHA256 и подпись KeePass проверяются) и вкладывает их в exe.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\build.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'Не найден csc.exe (.NET Framework 4.x)' }

$payload = Join-Path $here 'payload'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -Dir $root -FetchOnly $payload
if ($LASTEXITCODE -ne 0) { throw "Файлы из kit.json не прошли проверку (код $LASTEXITCODE)" }

$kit = Get-Content (Join-Path $root 'kit.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$res = @(
  ('-resource:{0},install.ps1' -f (Join-Path $root 'install.ps1')),
  ('-resource:{0},kit.json' -f (Join-Path $root 'kit.json'))
)
foreach ($item in @($kit.keepass) + @($kit.plugins)) { $res += ('-resource:{0},{1}' -f (Join-Path $payload $item.file), $item.file) }

$exe = Join-Path $here 'KeePass-Kit-Setup.exe'
& $csc -nologo -target:winexe -platform:anycpu -optimize+ -codepage:65001 `
  ('-win32manifest:{0}' -f (Join-Path $here 'admin.manifest')) `
  -reference:System.Windows.Forms.dll -reference:System.Drawing.dll `
  @res ('-out:{0}' -f $exe) (Join-Path $here 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "Ошибка компиляции (код $LASTEXITCODE)" }

# тихий установщик — тот же файл: режим он определяет по собственному имени (…-Silent.exe)
$silent = Join-Path $here 'KeePass-Kit-Setup-Silent.exe'
Copy-Item $exe $silent -Force
foreach ($f in $exe, $silent) { '{0}  {1} bytes  sha256 {2}' -f $f, (Get-Item $f).Length, (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() }
