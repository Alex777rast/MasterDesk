# MasterDesk

**Удобный удалённый доступ для поддержки российских пользователей.**

MasterDesk — независимая модифицированная сборка
[RustDesk](https://github.com/rustdesk/rustdesk) 1.4.9 для Windows x64.
Клиент заранее настроен на инфраструктуру `masterdesk.online`, использует
бренд MasterDesk и сохраняет возможность изменить параметры сервера в
интерфейсе.

> [!IMPORTANT]
> Файл пока не подписан Authenticode, поэтому SmartScreen может показать
> предупреждение. Сверяйте SHA-256 с файлом `SHA256.txt` из того же GitHub
> Release.

## Скачать

- Сайт проекта: <https://masterdesk.online/>
- Релизы и контрольные суммы:
  <https://github.com/Alex777rast/MasterDesk/releases>

## Что изменено

- название, иконки и интерфейс заменены на MasterDesk;
- ID-сервер по умолчанию: `hbbs.masterdesk.online`;
- relay-сервер по умолчанию: `hbbr.masterdesk.online`;
- API аккаунтов и адресной книги: `https://api.masterdesk.online`;
- добавлены настройки для российских сценариев поддержки и Windows RDS;
- реализован прямой выбор физического Windows-интерфейса для соединения с
  сервером MasterDesk при активном VPN/TUN;
- добавлена проверка новых сборок через HTTPS-канал MasterDesk с уведомлением
  в главном окне; автоматический запуск неподписанного обновления отключён;
- добавлены воспроизводимый PowerShell-скрипт и GitHub Actions-сборка Windows
  x64.

Полный перечень настроек и технических отличий находится в
[CUSTOM_BUILD.md](CUSTOM_BUILD.md).

## Сборка

Подготовка x64 к подписи запускается вручную через
[`masterdesk-windows.yml`](.github/workflows/masterdesk-windows.yml)
для нового номера beta (не ниже 107: локальная 106 уже использована для проверки). Она:

1. получает точный commit и все submodules, проверяет чистоту исходников;
2. устанавливает закреплённые версии Rust, Flutter, LLVM и vcpkg;
3. запускает `scripts/Build-CustomWindows.ps1`;
4. выполняет тесты MasterDesk;
5. сохраняет неподписанные EXE, payload, SHA-256 и сведения об исходниках
   как артефакты GitHub Actions.

Этот процесс **не публикует релизы, не запрашивает подпись и не меняет сайт**.
Существующие теги и EXE не пересобираются и не заменяются. Перед запуском нужно
опубликовать проверенные исходники и изменения submodule; грязное локальное
дерево не считается подтверждённым источником CI-сборки.

Ручная локальная сборка:

```powershell
pwsh -File .\scripts\Build-CustomWindows.ps1
pwsh -File .\scripts\Test-CustomDefaults.ps1
```

Результат следует правилу идентичности сборки:
`dist/MasterDesk-<version>-beta-<N>-<YYYY-MM-DD>-RDS-x86_64.exe`.

Опубликованная beta105 остаётся неподписанной portable-сборкой. Её точные хеши
и происхождение приведены в GitHub Release. `SOURCE_ATTRIBUTION.md` объясняет,
что historical base commit и автоматический архив GitHub не являются полным
снимком изменённых локальных исходников этой beta. Для следующего подписываемого
релиза требуется проверенный и опубликованный снимок, включая submodule.

Зависимость `libs/hbb_common` публикуется отдельно как видимый fork:
<https://github.com/Alex777rast/MasterDesk-hbb-common>.

## Code signing policy / Политика подписания кода

Подготовка ограничена x64. Одобрение SignPath Foundation пока не подтверждено;
наличие подготовительных файлов не означает наличие сертификата. Порядок,
роли и ограничения описаны в [SIGNING_POLICY.md](SIGNING_POLICY.md), следующие
шаги — в [инструкции подготовки](docs/signing-x64-preparation.md).

После одобрения будет использоваться атрибуция: Free code signing provided by
[SignPath.io](https://signpath.io/), certificate by
[SignPath Foundation](https://signpath.org/). Это не обещание устранить SmartScreen.

## Безопасность и допустимое использование

Используйте MasterDesk только для компьютеров, которыми вы владеете или на
управление которыми получили явное разрешение. Проект не поддерживает
несанкционированный доступ, скрытое управление или обход мер безопасности.

Уязвимости следует сообщать по инструкции в [SECURITY.md](SECURITY.md), не
публикуя чувствительные детали в обычном issue.

## Лицензия и происхождение

MasterDesk распространяется на условиях
[GNU Affero General Public License v3.0](LICENSE). Это изменённая версия
RustDesk, а не официальный релиз RustDesk и не продукт RustDesk, Inc.

Исходный проект и его история сохранены в fork. Сведения об авторских правах и
модификациях приведены в [NOTICE](NOTICE).

## Локальный GUI-тестовый контур

Для воспроизводимых Windows GUI-тестов используется RDP/VMware-контур с двумя
машинами: VM-A — управляемая, VM-B — управляющая. Чистые контрольные точки
`00-CLEAN-RDP-MCP-ON/OFF` содержат только RDP и Windows-MCP, без MasterDesk;
исходные `00-CLEAN-MASTERDESK-ON/OFF` сохранены отдельно.

Полный тест установки, реальной передачи мыши/клавиатуры B → A и переключения
удалённой раскладки запускается так:

```powershell
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action IdentityTest -Vm A -ExePath <candidate.exe>
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action PasswordTest -Vm All -ExePath <candidate.exe>
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action InputTest -Vm All -ExePath <candidate.exe>
```

`IdentityTest` installs from the clean MCP baseline and verifies that the ID is
unchanged across three service restarts. `PasswordTest` proves that an open
main GUI keeps temporary-password authorization available: VM-B sees the
password field instead of a mandatory approval wait, and VM-A Accept is never
clicked. `InputTest` restarts Windows-MCP only
after the final RDP desktop exists and selects the running RDP session from the
live UI tree, so Viewer size changes do not invalidate clicks. Beta 16 passed
the clean-baseline identity/password/input matrix. Beta 19 additionally passed
installation on both live VMs, full Flutter-payload verification, temporary-
password authentication, remembered-password reconnect and B → A attachment to
the active RDP session. Beta 60 additionally passed clean installation on both
VMs, exact runner/DLL/Flutter payload attribution and a host-driven RDP check of
the repaired Material Icons bundle. The user accepted the physical EN/RU
synchronization result. Current evidence is summarized in
`docs/current-state.md`.

Артефакты сохраняются в `artifacts/gui-runs/<timestamp>/`. Пароль RDP и разные
bearer-токены VM-A/VM-B не хранятся в репозитории, конфигурации или артефактах;
скрипты получают их только из пользовательских переменных окружения.

## Текущее состояние сервера

Production работает на exact image
`sha256:bada4754be4c41e5fef6cc9ce8540c7c13d19a93a36eb44969df569d3f2049a1`
в compatibility-режиме `N/N`. Исправлена повторная регистрация нового process
nonce той же authenticated installation без ожидания старой 45-секундной
аренды. Native direct/relay и WSS registration/reconnect/routing/relay canary-
тесты прошли; реальные VM прошли direct и forced-relay соединения. Порты
21118/21119 остаются loopback-only, внешний WSS доступен только через
Caddy/HTTPS 443. Свежий backup и остановленные recovery-контейнеры прежнего
exact image сохранены; подробности — в `artifacts/server-production-20260821/`.
