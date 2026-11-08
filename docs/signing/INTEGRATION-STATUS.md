# SignPath: чистая интеграция 2026-11-09

Реальная подпись, публикация релиза/сайта и production **не выполняются**.
Это подготовительная x64-ветка, не новый продуктовый EXE и не Free/Pro beta.
Данные аккаунтов/незавершённые продуктовые изменения остаются в исходном дереве.

## Исходники и безопасная техническая часть

- Ветка `codex/signpath-integration-20261109` основана на опубликованном reviewed
  `726b3cefa75e3890f0db36a80215d1ac13922676`, gitlink shared
  `1afc2f9d89e0e462da2cbf080e54f80e8f6984a2`.
- Перенесены только три подготовительных коммита, затем точечная интеграция.
  Старое грязное дерево и его index не переносятся и не очищаются.
- Manual unsigned workflow без SignPath submit/release; pinned Actions,
  all-file build-time manifest, exact origin/commit/gitlink/digest checks.
  Preflight workflow вызывается существующим dispatcher через workflow_call;
  его не требуется добавлять в default branch для этого вызова.
- Новый110+ beta reservation gate; один номер нельзя повторить даже после
  неудачной/неопубликованной сборки. Только эта job имеет contents:write.
- Подпись остаётся hard-disabled; config.enabled=false, approvedScope=[].
  Не надо вводить API token сейчас. Отдельный reviewed activation нужен позже.
- Результаты локальных/hosted проверок и фактические remote controls записываются
  в `docs/current-state.md` и локальные artifacts/signpath-integration-20261109.
  Наличие теста не является hosted/crypto/runtime PASS.

## GitHub: что проверить владельцу сейчас

Фактически настроено и повторно прочитано: rulesets26814262/26814264 Active,
без bypass; environment26655560539 с owner reviewer/admin bypassfalse и одной
branch policy65980450. Ветка опубликована. Hosted tooling
[run42526916619](https://github.com/Alex777rast/MasterDesk/actions/runs/42526916619)
прошёл на61d8e96 (45 Python + PS/metadata/source/ownership/defaults fixtures).
Номер beta не резервировался, EXE не собирался и не подписывался. Нынешние docs
и packet-helper дополнительно проверены локально; это не новый hosted product run.

1. Открыть https://github.com/settings/security → Two-factor authentication →
   Enable/проверить Enabled. Recovery codes сохранить у себя, не в чате/репозитории.
2. Открыть репозиторий → Settings → Rules → Rulesets. Для новой интеграционной
   ветки ожидаются Active запрет удаления и force-push; отдельно для
   `masterdesk-beta-reserved/*` запрет update/delete без bypass. Это НЕ защита
   default branch и НЕ обязательный PR review. Точные применённые настройки —
   в current-state, не считать этот список доказательством настройки.
3. Settings → Environments → masterdesk-signing: Required reviewers — владелец,
   Allow administrators to bypass — выключено, Deployment branches and tags →
   Selected branches → только `codex/signpath-integration-20261109` (Branch, не Tag).
   Владелец явно выбрал `solo` 2026-11-09. Prevent self-review оставить выключенным:
   workflow-trigger и release approval могут выполняться тем же владельцем,
   но каждый публичный SignPath request обязан получить явное ручное одобрение.
4. Выбор `solo` подтверждён: второй reviewer/code owner не назначается,
   обязательное approval собственного PR не включается. CODEOWNERS сохраняет
   владельца для чувствительных файлов, но не означает независимый peer review.
   Для внешних участников остаётся review владельца. На будущие публичные
   signing requests нужно его ручное подтверждение; автоматизация не одобряет
   подписи от его имени. Foundation ещё должна принять такую модель проекта.
5. Actions → MasterDesk x64 signing preparation (unsigned) → Run workflow →
   Branch: новая интеграционная → tooling_only:true → Run workflow. Это безопасная
   проверка tooling, без beta reservation/build/sign/release. Для настоящего
   unsigned candidate нужен новый номер110+ и tooling_only:false. Результат
   такого полного build ещё нельзя выдавать за проверенный до его выполнения.
6. Не merge в default `masterdesk-1.4.9`, не создавать version tag/release и не
   заменять опубликованные EXE. Привилегии production эта ветка не даёт.

## SignPath: после получения именно approval, не receipt

1. Открыть выданную Foundation организацию, включить MFA для владельца/approver.
   Не повторять заявку: подтверждение её получения уже было.
2. Projects → MasterDesk → Repository: Alex777rast/MasterDesk. Organization →
   Trusted Build Systems → добавить predefined GitHub.com, затем связать Project.
   GitHub App SignPath установить только для MasterDesk, не для всех repositories.
3. Signing policies → создать/проверить Release policy: Code signing certificate
   от Foundation, Use approval process, Required approvals:1 или согласованное
   большее число. Submitters — отдельный минимальный CI user, Approvers — человек;
   не включать auto-approve/test-policy для распространяемых beta.
4. Включить origin verification/согласованные build и SCM policies: exact repo,
   reviewed branch, hosted Windows, не PR/fork/arbitrary upload. Согласовать
   payload→portable repack→outer continuity, exact XML и product metadata.
5. Получить org/project/policy/artifact-config IDs и certificate subject/SHA256 из
   доверенного канала. Проверить proposed owned3 scope; desktop_drop/Flutter и
   чужие DLL не подписывать. Только после review заполнить approvedScope.
6. CI token владелец вводит непосредственно Settings → Environments →
   masterdesk-signing → Add environment secret → SIGNPATH_API_TOKEN.
   Не repository-wide secret, не лог/argv/чат. Сейчас secret не нужен.
7. Отдельно разрешить activation implementation, новый hosted candidate и
   реальные подписи. Проверить crypto/timestamp/content/repack/GUI acceptance.
   Публикация релиза/сайта — отдельное действие после этих gates.

## Неустранимые автоматически блокировки

- Foundation approval/certificate/allowed daily volume ещё не подтверждены.
- Нужны grants для exact default_net/hwcodec/impersonate-system revisions,
  workspace license attribution, FFmpeg GPL obligations, custom Flutter engine
  source/license и modified plugin lineage. License inventory не заменяет права.
- Foundation должна оценить fork/upstream signing и будущий Free/Pro500р/месяц
  hosted-service model. Не обещать eligibility, не скрывать коммерческую модель.
- Реальный submit/resume с durable intent ledger и provider integration,
  signed payload→repack→outer chain и положительные approved crypto/runtime tests
  остаются BLOCKED/NOT_RUN до разрешения. Никакие mock tests не означают подпись.
-14 inherited actionlint diagnostics/4 чужих workflow остаются отдельным FAIL,
  а private server compatibility assertion — отдельным прежним FAIL; они не
  ослаблены и не скрыты client-only подготовкой.

## Границы и откат новых GitHub настроек

Основная ветка, старые release refs/assets и настройки других веток не менялись.
Новые правила не требуют PR approval: это соответствует явному выбору `solo`.
После ответа владельца настройки повторно прочитаны GET-only: один owner reviewer,
Prevent self-review=false, admin bypass=false, одна разрешённая ветка, без
обязательного второго PR reviewer. Менять/ослаблять remote controls не потребовалось.
При необходимости остановки сначала оставить environment без signing secret и
не активировать template. Для отката ТОЛЬКО новых правил: Settings → Rules →
Rulesets → указанные выше имена → Enforcement status → Disabled → Save changes.
Старые правила не редактировать. Снимок исходного состояния и точные ответы API
сохранены локально; оба ruleset были новыми, environment ранее отсутствовал.
Не удалять beta reservations ради повторного выпуска номера.

Официальные инструкции: [GitHub environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
[rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository),
[SignPath projects/policies](https://docs.signpath.io/projects),
[trusted GitHub builds](https://docs.signpath.io/trusted-build-systems/github),
[Foundation terms](https://signpath.org/terms).
