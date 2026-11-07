# Архитектура подписания x64

Статус: unsigned preparation реализована; активного signing pipeline НЕТ.
Scope/IDs/certificate пока не согласованы. Никакой input или secret не активирует
подпись: в действующих workflows нет submit job, activation_guard всегда отказывает.

## Стадии и границы доверия

| Стадия | Подготовлено | Что ещё нельзя считать завершённым |
| --- | --- | --- |
| Source→hosted unsigned build | Existing clean-source gate, pinned tools, owned PE identity | Новый110+ hosted run после review/publication NOT_RUN |
| Upload→independent preflight | Exact API origin + digest + all-files manifest, negative tests | Actions execution NOT_RUN; SignPath connector не настроен |
| Выбор scope | Exact3 candidate filenames, approvedScope=[] | Licensing/fork approval BLOCKED |
| Owned payload signing | Инертный официальный action fragment, pinned SHA, XML restrictions | Org/project/policy/certificate IDs и provider approval отсутствуют |
| Signed output verification | Real Windows Authenticode/subject/cert SHA/EKU/timestamp + signtool; PE content comparator | Positive approved-output crypto test NOT_RUN |
| Signed payload→portable wrapper | Порядок ниже, existing packer source изучен | End-to-end signed repack и provider outer-origin acceptance BLOCKED |
| Outer signing/final verification | Отдельный XML draft и тот же signature verifier | Подпись/публикация НЕ разрешены |

Порядок после отдельной активации: verify unsigned→sign3 approved PE→verify
signatures и unchanged PE image→составить staged payload из original files +
ТОЛЬКО подписанных replacements→обновить `RustDllSha256` в
`data/masterdesk-build-manifest.json`→новый manifest всех staged files→portable
pack→проверить точное decoded payload→sign outer→verify signature + decode
original signed payload снова→final SHA256/provenance/request IDs.

`data/app.so` — Flutter AOT, не обычный Authenticode PE. Он и все upstream DLL,
assets, fonts должны сохранить исходные hashes. Старый build consistency
manifest меняется только осознанно: Rust DLL после подписи получает новый hash,
FlutterAotSha256 остаётся прежним. Запрещено повторно запускать metadata stamper
на подписанных файлах. `signed_content.py` допускает только PE checksum,
security-directory slot и appended WIN_CERTIFICATE с zero alignment; любые
другие изменения code/resources/overlay отвергаются. Это НЕ crypto verification.

## Особенность custom portable

`libs/portable/generate.py` встраивает Brotli records с MD5 для внутренней
распаковки и timestamp metadata. MD5 здесь НЕ security trust anchor: manifests
используют SHA256. Wrapper — не MSI, XML deep signing его содержимого не умеет
автоматически доказывать. Нужен hosted payload-first/repack/outer flow,
согласованный с Foundation; нельзя обойти origin verification локальной
перепаковкой/загрузкой готового EXE. Full build script сейчас stamp-ит unsigned
payload и wrapper; он НЕ готовый post-sign repack entrypoint. Не запускать его
поверх подписанных PE. Отдельная reviewed интеграция остаётся в owner/runbook gate.

## Подготовительные файлы

- `.signpath/config.example.json`: placeholders, enabled=false, approvedScope=[];
- `payload.xml.template`: exact3 PE, product/company/version restrictions;
- `outer.xml.template`: exact package parameter/metadata, не wildcard всехEXE;
- `signing-job.yml.template`: вне `.github/workflows`, hard false, protected
  environment, official submit actionf6d04783b4569d051e0c80105fe66e82819d0092;
- `scripts/signing/pipeline.py`, `preflight.py`, `Read-TrustedSigningArtifact.ps1`:
  только input/integrity, не запросы подписи;
- `Test-SignedArtifact.ps1`, `signed_content.py`: две независимые проверки
  результата. При отсутствии SDK/certificate/trust/timestamp — отказ.

[Artifact configuration](https://docs.signpath.io/artifact-configuration/)
разделяет включение upstream файлов и их подпись; nested signature не возникает
от подписи outer EXE. XML schema validation не равна provider acceptance.
