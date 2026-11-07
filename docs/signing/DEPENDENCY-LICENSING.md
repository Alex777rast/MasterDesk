# Лицензии и состав — 2026-11-08

Статус: инвентаризация PASS; юридическая совместимость и Foundation scope BLOCKED.
Никакие сторонние лицензии или Cargo.toml зависимостей не переписывались.

## Что действительно собрано

`scripts/signing/collect_inventory.py` использует locked/offline Cargo metadata,
target x86_64-pc-windows-msvc, features hwcodec,vram,flutter. Обходит reachable
non-dev graph, включая build dependencies. Отдельно читает локальные resolved
Dart packages, включая dev, native share/SPDX, vendored directories и parent licenses.

Результаты в `artifacts/signing-ready-20261108/dependencies-detailed/`
(первоначальный snapshot `dependencies/` также сохранён):

- `inventory.json`: 492 Cargo, 215 Dart, 19 native-cache ports, 8 vendored
  directories, 2 parent-license records. Всего736 записей, не736 runtime-библиотек.
- `source-build-graph.cdx.json`: CycloneDX1.5 с492 Cargo dependency nodes;
  Dart/native link graph не выдуман. Схема и отсутствие dangling refs проверяются
  `validate_sbom.py`; точное доказательство — `../sbom-detailed-validation.json`.
- `THIRD-PARTY-NOTICES.txt`: собранные исходные license/notice/copyright тексты
  с SHA256 и указанием компонента. Это evidence corpus, НЕ готовое юридически
  выверенное уведомление для распространения. Содержит также dev/build cache.

Формат выбран по [официальной CycloneDX1.5 схеме](https://cyclonedx.org/docs/1.5/json/).
Это SBOM исходного build-графа, НЕ аттестация точного состава hosted108 бинарника.
Cargo.lock совпадает с108, Cargo.toml уже отличается; прочие lock/native inputs
совпадают после нормализации CRLF. Native cache dirty. Всё это отражено в
`license-risk-evidence.json`; совпавший lockfile не доказывает linkage.
Detailed inventory отдельно сохраняет8 Dart Git revisions, public source URLs,
hosted archive hashes/lock-record hashes и Flutter SDK commit. URL с credentials
или query не экспортируется; raw lockfile остаётся контрольным source input.

`native-configuration.json`: Windows FFmpeg overlay явно использует
`--enable-gpl`; существующий local release log сообщает GPL version2 or later,
installed features amf/nvcodec/qsv. Copyright совпадает с GPLv2 текстом. Поэтому
нельзя объявлять эту сборку LGPL-only по общему описанию FFmpeg. Возможность
выбора GPLv3-or-later и совместимость combined work требует review условий и
точного linkage; flags/кеш не менялись. Это факт local cache, не аттестация108.

## Неоднозначные компоненты

| Компонент / revision | Найденное подтверждение | Вывод / действие |
| --- | --- | --- |
| allo-isolate0.1.25 | LICENSE указан файлом; текст и hash собраны | Нет license expression, но не считать отсутствием лицензии |
| rustdesk1.4.9 | LICENSE и LICENCE, одинаковый AGPLv3 SHA256 | Проверить corresponding source именно выпускаемых байтов |
| hbb_common0.1.0 | Собственный LICENSE/NOTICE, AGPLv3 | Точный опубликованный gitlink обязателен |
| clipboard/remote_printer/virtual_display | Локальные subtree без отдельного верхнего license | Проверить применимость parent-лицензии, не назначать автоматически |
| default_net78f8f70cd85151a3a2c4a3230d80d5272703c02e | [Cargo](https://github.com/rustdesk-org/default_net/blob/78f8f70cd85151a3a2c4a3230d80d5272703c02e/Cargo.toml); exact API tree без license-named файлов | NEEDS_UPSTREAM/владелец, нельзя вывести grant из отсутствия файла |
| hwcodec778df1f99597722473b29443bac22ae6c23946fe | [Cargo](https://github.com/rustdesk-org/hwcodec/blob/778df1f99597722473b29443bac22ae6c23946fe/Cargo.toml); exact tree без license-named файлов | Транзитивный риск для libmasterdesk и outer package |
| impersonate-system2f429010a5a10b1fe5eceb553c6672fd53d20167 | [Cargo](https://github.com/rustdesk-org/impersonate-system/blob/2f429010a5a10b1fe5eceb553c6672fd53d20167/Cargo.toml); exact tree без license-named файлов | Получить право для этой revision, не заимствовать лицензию из другого проекта |
| Flutter SDK packages3 + flutter_hbb | Parent SDK LICENSE и основная AGPL сохранены | Parent applicability требует проверки; не missing-license violation |
| ffmpeg/libyuv/pkgconf/ffnvcodec | Copyright/SPDX cache собраны; встречаются NOASSERTION/LicenseRef | Не лицензия по имени порта; проверять включённые codecs/config/static linkage |
| desktop_drop_plugin.dll | Собирается с patch из build script | Это modified upstream, не «неизменённый DLL»; signing исключён до fork review |
| flutter_windows.dll/custom engine | Pinned archive hash в build policy | Нужны source/build provenance для точного engine; не подписывать как свой |

В старом отчёте8 отсутствующих Cargo declarations считались с учётом license_file.
Теперь явно показаны9 без license expression, включая allo-isolate с LICENSE;
это не ухудшение графа и не девять доказанных нарушений. Из оставшихся8 main/shared
имеют отдельные license-файлы, часть workspace может подпадать под parent scope.
Неаутентифицированный дополнительный API-сбор сначала не удался; авторизованная
GET-проверка exact trees затем дала200/неусечённые ответы для всех трёх:
`github-controls-final.json`. Поиск имён файлов не доказывает отсутствие иных grants.

## Signing / inclusion matrix

| Компонент | Подписывать сертификатом проекта автоматически сейчас | После разрешения |
| --- | --- | --- |
| MasterDesk.exe, libmasterdesk.dll, dylib_virtual_display.dll | НЕТ: candidate-owned, approvedScope=[] | Только после прав/fork/provider review, exact origin и PE restrictions |
| Outer portable EXE | НЕТ | Проверка всех включённых компонентов и цепочки payload→repack→outer |
| Flutter/plugins/прочие upstream DLL | НЕТ | Включать только с подтверждёнными условиями; сохранить upstream bytes/signatures |
| data/app.so/assets/fonts | НЕ Authenticode PE targets | Контролировать hashes, Dart/assets/font notices/source obligations |
| Sciter, drivers, WinPE ISO, lab helpers, чужие EXE | ВНЕ scope | Отдельное задание/проверка, не расширять wildcard-ом |

Следующий юридический этап: определить точный distributed set для нового hosted
candidate, сформировать из corpus финальный notice bundle, проверить copyleft,
attribution/source/codec obligations и upstream rights; владелец/юрист/Foundation
решают неоднозначность. [AGPL текст](../../LICENSE), [политика](../../SIGNING_POLICY.md).
Отсутствие подтверждения = исключение из signing, не автоматический запрет всего OSS.
