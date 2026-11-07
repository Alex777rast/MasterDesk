# Изолированное исследование старого FAIL

`scripts/Test-ServerDefaults.ps1` запущен read-only08 ноября2026, exit1:
`Server compatibility mode can still reject partially upgraded clients.`
Доказательство: `artifacts/accounts-licensing-20261107/signing-server-recheck.log`.

Assertion на строках27–29 ожидает regex вида
`if !relay_security_required() { return true; }` в private deployment patch.
В текущем patch присутствует другой дизайн: RelayAuthorization::from_verification
возвращает CompatibilityBypass для Missing/Invalid, если required=false; аналог
для RelayTicketAuthorization используется в relay path. Следовательно, отсутствие
прежней текстовой формы само по себе не доказывает runtime несовместимость.
Это установленный mismatch формы assertion и исходника, НЕ доказательство
полной корректности нового handshake/production configuration.

Scope assertion не ослаблен/не отключён; patch, сервисы и security policy не
менялись. В полном defaults gate серверная проверка остаётся по умолчанию;
в public client-only gate она явно NOT_RUN. FAIL не превращён в PASS.

Исправление требует отдельного server-scoped задания: executable regression
матрица required=true/false, Missing/Invalid/Verified, ticket pairing/replay и
реальные direct/relay canaries с точным image/config/key attribution. Просто
добавить строку, угодную regex, было бы обходом проверки. Это вне signing-prep
и не разрешает менять production. Точная хеш-атрибуция patch включена в final evidence.
