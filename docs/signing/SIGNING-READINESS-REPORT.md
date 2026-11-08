# SignPath readiness — 2026-11-08

Historical checkpoint. The 2026-11-09 clean integration supersedes the source/CI
boundary and pending GitHub setup below; see [current status](INTEGRATION-STATUS.md).
The legal/provider/positive-signature blockers remain. Old evidence is retained,
not relabelled as a test of the new integration.

**Unsigned preparation: реализована и проверяется локально. Реальная подпись:
BLOCKED. Не одобренный, не подписанный и не опубликованный релиз.**

Ветка `codex/signpath-foundation-prep-20261108`. Основание dirty worktree
3789ef02e2b022ebc9217353f9578f940418cc79 сохранено; helper/documentation commits
не являются complete release source snapshot. Точные commits и hashes — в
`artifacts/signing-ready-20261108/final-attribution.json` после итоговой проверки.
Подготовительные изменения существовавших dirty workflow/CODEOWNERS/state
оставляются отдельными unstaged hunks, не коммитятся с чужими изменениями.

## Выполнено

- Новая матрица [compliance](SIGNPATH-FOUNDATION-COMPLIANCE.md) по официальным
  требованиям; различены факт, гипотеза, NEEDS_OWNER и provider decision.
- [Полный source-graph inventory](DEPENDENCY-LICENSING.md), license text corpus,
  CycloneDX1.5 и точные версии/revisions; remote checks неоднозначных grants.
- [Origin/identity](BUILD-PROVENANCE.md), [архитектура](SIGNING-ARCHITECTURE.md),
  [threat model](SIGNING-SECURITY.md), [runbook](SIGNING-RUNBOOK.md),
  [owner actions](FOUNDATION-OWNER-ACTIONS.md), [review packet](FOUNDATION-REVIEW-PACKET.md).
- Fail-closed unsigned preflight: authenticated exact GitHub run/artifacts,
  archive digest, commit/gitlink, all-file SHA256 manifest, negative fixtures.
- Подготовлены inert XML/config/action templates с пустым approvedScope.
  Реального signing job нет; activation_guard не допускает включение flags/secret.
- Real Authenticode verifier и отдельный PE unchanged-content verifier; они не
  создают подпись. Нет fictitious Foundation/certificate IDs или mock crypto PASS.

## Проверки и доказательства

Все пути ниже относительно `artifacts/signing-ready-20261108/`, кроме явно
указанных старых helper logs. Итоговые counts подтверждать по final-attribution.

| Проверка | Статус | Доказательство / граница |
| --- | --- | --- |
| Signing integrity/negative tests | PASS | all-signing-tests-complete.log:31 tests; synthetic bytes, не запуск программы |
| Metadata/source helpers | PASS | ../accounts-licensing-20261107/signing-prep-recheck.log:7 metadata,4 source,2 ownership,10 syntax |
| Defaults-scope guards | PASS | ../accounts-licensing-20261107/signing-scope-recheck.log:13 fixtures |
| PowerShell syntax/real signature rejection | PASS | safety-packet/result.json;6 scripts, unsigned и wrong signer отвергнуты без изменения bytes |
| CycloneDX schema + refs | PASS | sbom-detailed-validation.json:736 components,492 dependency nodes |
| Provider XML official XSD | PASS | provider-xml-dotnet.json: exact unmodified XSD, System.Xml |
| Новые/изменённые workflows actionlint | PASS | actionlint-final.log; hosted dispatch НЕ выполнялся |
| Полный actionlint унаследованных workflows | FAIL | actionlint-all.log:14 diagnostics/4 files вне signing path; не скрыты |
| Pure decode immutable108 | PASS | beta108-content-recheck.json:100 files,78218180 bytes; SHA ниже |
| New client Cargo/default tests | PASS | client-defaults-initialized.log:22 Rust/portable tests + client assertions; server explicitly NOT_RUN |
| Flutter account regressions | PASS (предыдущий этап этого же turn) |26 widget/model tests и analyzer0issues; НЕ новый signing GUI acceptance |
| Existing private server assertion | FAIL | [исследование](SERVER-PATCH-COMPATIBILITY.md); не отключён и не исправлен формально |
| Effective GitHub branch/environment controls | NEEDS_OWNER | github-controls-final.json: unprotected2 branches, rulesets/environment empty |
| GitHub MFA | NEEDS_OWNER | API fieldnull, не false |
| SignPath approval/MFA/policies/certificate | BLOCKED | Receipt не approval; значения неизвестны |
| Positive approved crypto/timestamp test | NOT_RUN | Нет подписанного approved output; не mock |
| New hosted CI / bit-for-bit rebuild | NOT_RUN | Никакого push/dispatch/build product |
| Signed payload→repack→outer chain | BLOCKED | Provider origin review + отдельная реализация/авторизация; не готовый production pipeline |
| Source publication / clean release tree | BLOCKED | source-gate-current.json:NOT_READY, dirty/untracked source сохранён; source-only helper commits не решают это |
| New GUI/install/update/uninstall/direct/relay/SmartScreen | NOT_RUN | ВМ/системы не изменялись, actual signing запрещён |

Официальная XSD содержит regex, который libxml2/lxml не компилирует. Первая
попытка оставлена как evidence; неизменённая схема успешно проверена штатным
System.Xml. Это не подавление schema error изменением/удалением ограничения.

Первый запуск client gate не имел LIBCLANG_PATH и завершился build failure;
после штатного Initialize-MasterDeskBuildEnvironment тот же gate завершился
PASS22 без очистки кеша. Логи initial/final раздельные. Никакого product package
не создавалось; Cargo скомпилировал unit-test executables, они не release candidate.

Review ZIP создаётся `New-FoundationReviewPacket.ps1` из явного списка текстовых
документов/evidence, с hashes каждого entry и повторной проверкой содержимого.
Внешний/существующий output отвергнуты2 negative cases. EXE/keys/venv/private
configs не включаются; high-confidence secret-indicator scan не заменяет review
владельца. Пакет остаётся локальным draft, никому не отправлен.

## Неизменность и оставшееся

108: `MasterDesk-1.4.9-10-beta-108-2026-11-06-RDS-x86_64.exe`,
SHA256 `0A21163AC5D3DA8448C645195E3F26746B43E772FF4E9CDDE74955CAD934E0E3`.
105 x64/x86,106,108 и внутренний109 перепроверяются по точным прежним hashes;
107 identity остаётся зарезервированной, новой сборки/переименования107 нет.
Оригинальные archives, published releases/tags и все beta bytes не изменены.

Signing-подготовка не меняла product/auth/Free-Pro implementation, серверы/контейнеры/production
configuration, сайт/mirrors, VMware/снимки и другие автоматизации. Предшествующий
account vault fix сохранён отдельным checkpoint; разрешённый test-container
upgrade не выполнялся после переключения на это задание.

До реальной подписи остаются legal/source/fork review, GitHub enforcement/MFA,
Foundation approval/configuration, полный новый reviewed hosted source и
provider-approved payload/repack/outer chain. Действия владельца перечислены
отдельно. Не гарантируется ни одобрение проекта, ни исчезновение SmartScreen.
