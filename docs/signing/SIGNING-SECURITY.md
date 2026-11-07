# Угрозы и enforcement

Проверено08 ноября2026. Токены/ключи не создавались. GET-only audit использовал
существующую GitHub credential только в памяти/stdin; значения не пишутся в
argv, reports или вывод. Никаких удалённых настроек не изменено.

## Реальные настройки GitHub

`artifacts/signing-ready-20261108/github-controls-final.json`:

- Repository public fork `Alex777rast/MasterDesk`, parent `rustdesk/rustdesk`.
- Default branch `masterdesk-1.4.9` и reviewed preparation branch
  `codex/x64-signing-source-20261106`: protected=false, protection404,
  active rules200/[], rulesets200/[] (включая parents).
- Environments200/[]: защищённого `masterdesk-signing` пока НЕТ.
- Default token permissions read, PR approval token=false.
- Authenticated owner, но MFA поле null: NOT_RUN/NEEDS_OWNER, не MFA=false.
- SignPath permissions/MFA/manual policy/certificate: BLOCKED до approval/setup.

Вывод: локальный CODEOWNERS не обеспечивает обязательный review. Подпись пока
не допускается. Владелец должен отдельно подтвердить/настроить protection,
обязательные checks, code-owner review, запрет force/delete, no bypass и
environment reviewers. API403/404 сами по себе не всегда доказывают отсутствие
правила; здесь вывод дополнительно подтверждён protected=false и пустыми active
rules/rulesets. Проверка не охватывает все private account/organization settings.
[GitHub protection API](https://docs.github.com/en/rest/branches/branch-protection).

## Threat→control

| Угроза | Реализованный барьер | Остаток |
| --- | --- | --- |
| Arbitrary EXE/URL upload | Нет такого workflow input; exact run/repo/name/digest | Provider-side origin ещё обязателен |
| Fork/PR/failed/rerun artifact | Dispatch/reviewed branch/attempt1/workflow ID/head repo checks | Защита самой reviewed ветки отсутствует |
| Подмена manifest или DLL | SHA256 всех файлов, exact set, external archive digest | JSON сам себя не аутентифицирует |
| Submodule mismatch | Manifest против API git tree commit | Публичность exact source/keys проверять отдельно |
| Scope wildcard/подпись upstream | Exact3 candidates; approvedScope пуст; metadata XML | Юридический/provider clearance открыт |
| Возврат другой программы вместо подписи | PE unchanged-image comparator + expected signer cert/subject | Real signed end-to-end NOT_RUN |
| ZIP traversal/ADS/case aliases/reparse | Raw original name validation, size bounds, exact hashes, fresh destination | Все consumer/extractors будущего workflow должны сохранять это свойство |
| Token theft/untrusted code | No signing token/job; read-only preflight; no artifact execution | Future signer обязан быть isolated approved environment |
| Неявное включение подписи | activation_guard всегда BLOCKED; disabled template вне workflows | Требуется отдельный reviewed activation diff |

`artifacts/signing-ready-20261108/workflows-audit.json` инвентаризирует13 локальных
workflows: обнаруженные external actions закреплены40hex SHA. Signing/preflight
не используют third-party release upload, self-hosted runner, PR-target trigger
или произвольный executable. В унаследованных upstream workflows есть
contents:write, secrets:inherit, build/release/signing иных платформ и application
caches. Они НЕ входят в Foundation trust path и не получают signing secret.
Их массовое изменение без необходимости не выполнялось. Text scan не равен
полной оценке reachable shell code или фактической конфигурации каждого action.

Полный локальный actionlint13 workflows дал FAIL:14 diagnostics в четырёх
унаследованных файлах ci.yml, flutter-build.yml, playground.yml,
third-party-RustDeskTempTopMostWindow.yml (неопределённые matrix/input values,
set-output, False и intentionally-false jobs/default+required). Лог
`actionlint-all.log` сохранён. Signing/preflight2 workflow отдельно PASS.
Эти старые cross-platform/release paths не входят в Foundation flow; их не
переопределяли массово ради общего зелёного результата. Перед использованием
любой из этих цепочек потребуется отдельное исправление/проверка.

Принцип минимальных permissions, action pinning и отдельный защищённый signing
job соответствуют [GitHub secure use](https://docs.github.com/en/actions/reference/security/secure-use).
Перед активацией проверить весь transitive action code, а не только SHA/YAML.
Official SignPath v3 SHA разрешён по git ref и его action.yml прочитан; это
НЕ завершённый независимый аудит bundled index.js.

[SignPath project policies](https://docs.signpath.io/projects) должны ограничивать
repository/branch, origin, submitter и approver независимо от GitHub jobs.
API token не выдаёт право обходить эти ограничения. Для CI использовать отдельного
минимального submitter; персональные credentials не переносить в workflow.
[Managing users](https://docs.signpath.io/users/).

Ротация сертификата требует нового reviewed SHA256 pin. Отсутствие timestamps,
неизвестная chain/subject, SDK errors/warnings или несовпавший hash не допускают
продолжения. Signature verifier ничего не подписывает и не модифицирует.
