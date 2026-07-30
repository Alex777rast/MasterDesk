# MasterDesk

**Удобный удалённый доступ для поддержки российских пользователей.**

MasterDesk — независимая модифицированная сборка
[RustDesk](https://github.com/rustdesk/rustdesk) 1.4.9 для Windows x64.
Клиент заранее настроен на инфраструктуру `masteronline.space`, использует
бренд MasterDesk и сохраняет возможность изменить параметры сервера в
интерфейсе.

> [!IMPORTANT]
> Файл пока не подписан Authenticode, поэтому SmartScreen может показать
> предупреждение. Сверяйте SHA-256 с файлом `SHA256.txt` из того же GitHub
> Release.

## Скачать

- Сайт проекта: <https://masteronline.space/>
- Релизы и контрольные суммы:
  <https://github.com/Alex777rast/MasterDesk/releases>

## Что изменено

- название, иконки и интерфейс заменены на MasterDesk;
- ID/relay-сервер по умолчанию: `desk.masteronline.space`;
- добавлены настройки для российских сценариев поддержки и Windows RDS;
- реализован прямой выбор физического Windows-интерфейса для соединения с
  сервером MasterDesk при активном VPN/TUN;
- отключено обновление из официального канала RustDesk;
- добавлены воспроизводимый PowerShell-скрипт и GitHub Actions-сборка Windows
  x64.

Полный перечень настроек и технических отличий находится в
[CUSTOM_BUILD.md](CUSTOM_BUILD.md).

## Сборка

Для каждого тега `v*` workflow
[`masterdesk-windows.yml`](.github/workflows/masterdesk-windows.yml):

1. получает этот commit и все submodules;
2. устанавливает закреплённые версии Rust, Flutter, LLVM и vcpkg;
3. запускает `scripts/Build-CustomWindows.ps1`;
4. выполняет тесты MasterDesk;
5. публикует EXE, SHA-256 и идентификатор исходного commit;
6. для тега создаёт GitHub Release.

Ручная локальная сборка:

```powershell
pwsh -File .\scripts\Build-CustomWindows.ps1
pwsh -File .\scripts\Test-CustomDefaults.ps1
```

Результат: `dist/MasterDesk-1.4.9-RDS-x86_64.exe`.

Зависимость `libs/hbb_common` публикуется отдельно как видимый fork:
<https://github.com/Alex777rast/MasterDesk-hbb-common>.

## Code signing policy / Политика подписания кода

После одобрения проекта SignPath Foundation workflow можно переключить на
подписание артефакта, собранного GitHub-hosted runner. Порядок, роли и
ограничения описаны в [SIGNING_POLICY.md](SIGNING_POLICY.md).

Free code signing provided by [SignPath.io](https://signpath.io/), certificate
by [SignPath Foundation](https://signpath.org/).

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
