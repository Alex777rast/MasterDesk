# Соответствие SignPath Foundation — 2026-11-08

Это техническая проверка, не одобрение и не юридическое заключение. Заявка
получена Foundation; решения пока нет. Автоматический scope пуст.
Доказательства ниже находятся в `artifacts/signing-ready-20261108/` (E).
Исторические отчёты 20261106 не заменяются. Сборка108 и текущий dirty tree различны.

| Требование | Состояние / доказательство | Пробел | Автоматически / ответственная сторона | Источник |
| --- | --- | --- | --- | --- |
| OSS, без proprietary/dual-license | LICENSE/LICENCE: AGPLv3; E/dependencies | Транзитивные права; будущий Free/Pro | Сбор данных сделан; владелец/юрист/Foundation | [Условия](https://signpath.org/terms) |
| Поддерживаемый выпущенный проект | Публичные105, hosted108; README | Репутация оценивается Foundation | Нет; Foundation | [Условия](https://signpath.org/terms) |
| Собственный maintained fork | GitHub API: fork RustDesk | Подписанная upstream-линия и review изменений | Частично; владелец/Foundation | [Условия](https://signpath.org/terms) |
| Scope только своих binaries | config.example.json: approvedScope=[] | Три PE лишь кандидаты; зависимости не разрешены | Блокировка готова; Foundation | [Условия](https://signpath.org/terms) |
| Не обходить защиту/приватность | README/PRIVACY, обычная авторизация | Новый runtime/installation/privacy acceptance NOT_RUN | Не в этом задании; владелец | [Условия](https://signpath.org/terms) |
| Предупреждать об установке, удаление | Portable default, GUI install/update policy | Новый GUI/uninstall цикл NOT_RUN | Не менять ВМ; владелец | [Условия](https://signpath.org/terms) |
| MFA и роли | SIGNING_POLICY; API MFA=null | GitHub и SignPath MFA не подтверждены | Нет; владелец | [Условия](https://signpath.org/terms) |
| Публичная signing/privacy policy | README, SIGNING_POLICY, PRIVACY | Продвижение на сайт/default branch не выполнено | Только отдельная публикация владельца | [Условия](https://signpath.org/terms) |
| Manual approval каждой подписи | Инертный шаблон; signing job отсутствует | Provider approver ещё не настроен | После одобрения; владелец/Foundation | [Условия](https://signpath.org/terms) |
| Метаданные PE ограничены | Два XML-шаблона, product/company/version | Provider activation NOT_RUN | Проверяется XSD; Foundation | [Reference](https://docs.signpath.io/artifact-configuration/reference) |
| Проверяемый build origin | Hosted108 + digest proof; новый preflight | Новая версия workflow не запускалась | Да, после review/push; [GitHub connector](https://docs.signpath.io/trusted-build-systems/github) |
| Раздельные signing policies | config placeholders, payload/outer templates | IDs, certificate, origin continuity неизвестны | Владелец/Foundation; [Projects](https://docs.signpath.io/projects) |
| Доверенная подпись и timestamp | Test-SignedArtifact.ps1 | Реального approved output нет | После одобрения; [Reference](https://docs.signpath.io/artifact-configuration/reference) |

Отсутствие поля Cargo license НЕ означает отсутствие лицензии. Платный сервис
сам по себе НЕ равен proprietary/dual licensing. Нужно отдельно согласовать с
Foundation точную модель распространения AGPL-клиента и Free/Pro: открытые
исходники и права получателя не должны подменяться условиями подписки.
Лицензии не менялись, платные функции не изменялись. Нельзя гарантировать
принятие проекта или отсутствие дополнительных требований Foundation.

Реальное enforcement проверено API: две исследованные ветки protected=false,
active branch rules=[], rulesets=[], environments=[]; файл CODEOWNERS сам по
себе не включает review. Это не утверждение о всех возможных настройках аккаунта.
Подробности и границы — [security](SIGNING-SECURITY.md), [действия](FOUNDATION-OWNER-ACTIONS.md).

Дополнительный primary source: [объявление maintainer RustDesk](https://github.com/rustdesk/rustdesk/discussions/13757)
описывает подпись GitHub releases через Certum19 декабря2025. Это свидетельство
практики upstream, но НЕ проверка сертификата точного upstream1.4.9 артефакта или
приемлемости конкретной MasterDesk release branch. Эти пункты остаются открытыми;
подпись Git commit/tag нельзя выдавать за Authenticode подпись EXE.
