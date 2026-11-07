# Runbook: до и после одобрения

Сейчас разрешена только подготовка. НЕТ команды «подписать сейчас».
Нельзя включить подписание подстановкой IDs или enabled=true. Никогда не
передавать токены в чат/артефакты или подавать локальную beta108 как hosted input.

## Повторяемые безопасные проверки

Из корня, PowerShell7; сохранять новые outputs, не перезаписывать доказательства:

```powershell
. ./scripts/Initialize-MasterDeskBuildEnvironment.ps1
& $env:MASTERDESK_PYTHON -m unittest discover -s scripts/signing -p 'test_*.py' -v
./scripts/Test-MasterDeskSigningPreparation.ps1
./scripts/Test-DefaultsScope.ps1
./scripts/Test-CustomDefaults.ps1 -ClientOnly
./scripts/signing/Test-SigningSafety.ps1 -OutputDirectory artifacts/signing-safety-NEW
./scripts/signing/Read-GitHubSigningControls.ps1 -OutputPath artifacts/github-controls-NEW.json
git diff --check
```

`Test-ServerDefaults.ps1` проверять отдельно: сохранён FAIL существующего
compatibility assertion, client-only PASS его не отменяет. No VM mutations.
SBOM collector требует fresh `--out` и existing Flutter/vcpkg caches; параметры
зафиксированы в скрипте. Schema validator использует isolated jsonschema4.23.0
venv; dependency install log сохранён в evidence, это не runtime-зависимость продукта.

## Gates после approval — пока BLOCKED/NEEDS_OWNER

1. Получить именно approval, не receipt заявки. Согласовать paid-service/OSS,
   fork lineage, licensing risks и exact3-owned scope; иначе scope остаётся пуст.
2. Владелец подтверждает MFA, роли, branch/ruleset enforcement и reviewers
   environment `masterdesk-signing`. Повторить GET audit. Секрет отдельно вводит
   владелец через protected GitHub environment, не через CLI argv/репозиторий.
3. Foundation выдаёт org/project/policy/artifact-config/certificate details.
   Получить signer subject/certificate SHA256 и trust chain из доверенного канала.
   XML validate против текущей official XSD, затем provider sample/config review.
4. Review полный corresponding source/client+submodules. Отдельное разрешение на
   push/PR. Не коммитить накопленный dirty tree автоматически. Создать новый
   beta110+ с actual date/embedded identity.108/109 нельзя переиздать.
5. Hosted unsigned build и independent preflight должны пройти. Verify commit,
   gitlinks, artifact IDs/digests, all-file manifest и источник каждого input.
   Не использовать PR/fork/failed/rerun/local artifacts. Текущий preflight ещё
   не запускался; его local fixtures не заменяют hosted PASS.
6. Согласовать с Foundation origin continuity для TWO signing requests и custom
   portable repack. Нет автоматического deep signing формата Rust portable.
   Подготовить отдельный reviewed hosted job, не запускать обычный full build
   поверх signed files: он содержит metadata stamping.
7. Только после отдельного разрешения изменить inert template на настоящий
   signing job. Удалять hard false допустимо лишь reviewed activation commit.
   Manual approval требуется и в SignPath; сначала exact verified owned payload
   upload, затем официальный connector. Никаких произвольных artifact IDs из UI.
8. На каждом returned PE выполнить две проверки:

```powershell
& $env:MASTERDESK_PYTHON scripts/signing/signed_content.py --unsigned VERIFIED_INPUT --signed PROVIDER_OUTPUT
./scripts/signing/Test-SignedArtifact.ps1 -Path PROVIDER_OUTPUT `
  -ExpectedCertificateSha256 APPROVED_CERT_SHA256 -ExpectedSubject APPROVED_SUBJECT `
  -ExpectedProductVersion EXACT_BETA_VERSION -OutputPath NEW_SIGNATURE_REPORT
```

   Это placeholders, не готовые реальные значения. Проверка использует Windows
   Authenticode, pinned certificate/subject, code signing EKU, timestamp и SDK
   `signtool verify /pa /all /tw`; warning/error — отказ. Она не создаёт сертификат.
   [Microsoft SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool).
9. Собрать staging только из verified input + approved replacements. Upstream
   DLL/AOT/assets неизменны. Refresh RustDllSha256, full signed manifest; pack
   hosted wrapper с новой допустимой identity без stamping signed payload.
   Verify pure decoded archive в точности; sign outer отдельным approved policy.
10. Проверить outer подпись/identity и неизменность image, decoded signed payload,
    все inner signatures/third-party hashes, final SHA256. Сохранить request IDs,
    original/final manifests, GitHub run/artifact IDs и certificate/timestamp data.
11. Отдельно авторизовать GUI/install/update/uninstall/direct/relay acceptance на
    стендах. Только затем отдельное разрешение на release/site/mirrors. Подпись
    не гарантирует отсутствие SmartScreen/AV предупреждений.

Если любой gate FAIL/BLOCKED — не ослаблять его. Остановить именно signing flow,
сохранить доказательства. Не делать retry с другим файлом под старой beta/version.
