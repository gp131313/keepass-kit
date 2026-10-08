# KeePass Kit — KeePass с плагинами и настройками одной командой

Установщик, который приводит KeePass на Windows-компьютере к одному виду: ставит или обновляет [KeePass 2.x](https://keepass.info/), кладёт нужные плагины, включает настройки и автозапуск, открывает базу из папки Dropbox и защищает SSH-агент KeeAgent от службы Windows `ssh-agent`.

Это не форк KeePass. Внутри — официальный подписанный установщик KeePass и релизы плагинов без изменений; версии и SHA256 закреплены в [`kit.json`](kit.json), подпись установщика KeePass проверяется при сборке и при установке.

## Что делает

| Шаг | Что происходит |
|---|---|
| KeePass | ставит KeePass 2.61.1, если его нет или версия старше; более новую не трогает |
| KeeAgent 0.13.8 | SSH-агент из базы KeePass для `ssh.exe` (канал Windows OpenSSH) |
| KeePassWinHello 3.3.1 | вход в базу отпечатком, лицом или PIN Windows Hello; только если есть сканер или камера Windows Hello |
| Yet Another Favicon Downloader 1.2.5.0 | значки сайтов у записей |
| Лишние плагины | удаляет `KeePassHttp` (заброшен, слабый протокол), старый `KeePassFaviconDownloader` и дубль `KeeAgent.dll` |
| Настройки KeePass | запуск свёрнутым и заблокированным, без проверки обновлений (обновляет [win-auto-update](https://github.com/gp131313/win-auto-update)); KeeAgent: канал Windows OpenSSH, разблокировка базы по запросу |
| База | если в конфиге нет последней базы, ищет единственный `.kdbx` в папке Dropbox и делает его последним открытым |
| Автозапуск | KeePass стартует вместе с Windows |
| Служба `ssh-agent` | отключает её и ставит сторожа — задачу Планировщика от SYSTEM, которая вернёт службу в `Disabled`, если её снова включит установка или обновление OpenSSH |

Повторный запуск безопасен: меняется только то, что расходится с `kit.json`. Если менять нечего, KeePass не закрывается. Если есть что менять, открытый KeePass закрывается (`--exit-all`) и после установки запускается снова — без прав администратора, как обычно.

Журнал: `%ProgramData%\KeePassKit\install.log`. Перед правкой конфига его копия сохраняется рядом как `KeePass.config.xml.kit-backup`.

## Установка

### Один файл

1. Скачайте из [релиза](https://github.com/gp131313/keepass-kit/releases/latest) **`KeePass-Kit-Setup.exe`**.
2. Запустите и один раз нажмите «Да» в окне UAC.
3. «Установить» → «Готово».

`KeePass-Kit-Setup-Silent.exe` ставит без окон (то же даёт ключ `/silent`). Ключи установщика:

| Ключ | Смысл |
|---|---|
| `/silent` | без окон |
| `/withwinhello` | ставить KeePassWinHello и без сканера |
| `/nowinhello` | не ставить KeePassWinHello |
| `/noguard` | не трогать службу `ssh-agent` |
| `/nostart` | не запускать KeePass в конце |

После установки KeePassWinHello вход по отпечатку заработает, когда база один раз будет открыта мастер-паролем.

### Из папки репозитория

Двойной клик по **`Install.cmd`**. Установщик KeePass и плагины `install.ps1` скачает сам и сверит с `kit.json`.

Посмотреть, что изменится, ничего не меняя (права администратора не нужны):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

Только настройки текущего пользователя (конфиг, автозапуск), без прав администратора — `-UserOnly`. Нужно, если установщик запускали от другой учётной записи администратора: тогда он ставит программу и плагины, а пользовательскую часть пропускает.

## Обновить версии

1. В `kit.json` поменять версию, адрес и SHA256 у KeePass или плагина (SHA256 установщика KeePass публикуется на [keepass.info/integrity.html](https://keepass.info/integrity.html)).
2. Собрать exe заново.

## Сборка из исходников

Нужен только Windows: компилятор C# из состава .NET Framework 4.x, SDK не нужен.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup\build.ps1
```

`build.ps1` скачивает файлы из `kit.json` в `setup\payload`, проверяет SHA256 и подпись KeePass, вкладывает их в `setup\KeePass-Kit-Setup.exe` и делает копию `KeePass-Kit-Setup-Silent.exe`.

## Ограничения

- Windows 10/11, для установки нужны права администратора.
- exe не подписан: SmartScreen может показать «Windows защитила ваш компьютер» → «Подробнее» → «Выполнить в любом случае».
- База KeePass в комплект не входит. Dropbox должен быть установлен и досинхронизирован; файл базы — «Доступен в автономном режиме».
- Сторож пишет в `C:\ClaudeScripts\sshagent-guard` (путь задаётся в `kit.json`). Убрать: `Unregister-ScheduledTask 'SSH-Agent Guard (KeeAgent)' -Confirm:$false` от администратора и удалить папку.
- Windows Hello пускает и по PIN: база на этом компьютере защищена не сильнее PIN Windows.

## Поддержать

Если набор пригодился — можно кинуть на кофе:

- **Dogecoin (DOGE)**: `D7z9UaBsmcV7EqJo5Y5fdLG9xUNw47dNgr`

Подробнее — в [DONATE.md](DONATE.md).

## Лицензия

Скрипты и установщик — [MIT](LICENSE). Вложенные программы распространяются без изменений на условиях их авторов: KeePass — GPL-2.0 (Dominik Reichl), KeeAgent — GPL-2.0 (David Lechner), KeePassWinHello — MIT (sirAndros), Yet Another Favicon Downloader — MIT (navossoc).

## English

One-shot installer that brings KeePass 2.x on a Windows PC to a standard state: installs or updates KeePass (official signed installer), adds KeeAgent (SSH agent over the Windows OpenSSH pipe), KeePassWinHello (Windows Hello unlock, only when a biometric device is present) and Yet Another Favicon Downloader, removes KeePassHttp and the old KeePassFaviconDownloader, sets start minimized and locked, autostart and the last database from Dropbox, and disables the Windows `ssh-agent` service with a SYSTEM guard task so KeeAgent keeps the pipe. Versions and SHA256 are pinned in `kit.json`; re-running is safe. Download `KeePass-Kit-Setup.exe` from Releases, or run `Install.cmd` from the repo; `install.ps1 -DryRun` shows what would change. Build: `setup\build.ps1` (csc from .NET Framework, no SDK). Scripts are MIT; bundled KeePass and KeeAgent are GPL-2.0, KeePassWinHello and Yet Another Favicon Downloader are MIT.
