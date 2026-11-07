# Происхождение сборок

## Не смешивать три состояния

| Состояние | Идентичность | Значение |
| --- | --- | --- |
| Неизменяемая hosted108 | source99441ca7182f49b55b6e62726b50850c24343018, shared1afc2f9d89e0e462da2cbf080e54f80e8f6984a2 | Реальная историческая unsigned build |
| Source-only signing review06 ноября |726b3cefa75e3890f0db36a80215d1ac13922676 | Не является источником уже собранных108 байтов |
| Текущая подготовка08 ноября | codex/signpath-foundation-prep-20261108, base3789ef02e2b022ebc9217353f9578f940418cc79 | Dirty product tree сохранён; новые helper commits не аттестуют его как release source |

Source108 [полный run](https://github.com/Alex777rast/MasterDesk/actions/runs/42231650980),
[отдельный CLI proof](https://github.com/Alex777rast/MasterDesk/actions/runs/42239997357).
Второй использовал tooling0be09bf23715e5b65a319902290d99969dfafcbd, не пересобирал108.

108: `MasterDesk-1.4.9-10-beta-108-2026-11-06-RDS-x86_64.exe`,24792576 bytes,
SHA256 `0A21163AC5D3DA8448C645195E3F26746B43E772FF4E9CDDE74955CAD934E0E3`,
Authenticode NotSigned. Повторный pure decode08 ноября подтвердил100 файлов,
78218180 bytes, точный состав и hashes. Wrapper/GUI не запускались.
`artifacts/signing-ready-20261108/beta108-content-recheck.json`.

## Новая цепочка доказательств

1. Review/publish полный соответствующий source и recursive gitlinks по отдельному
   разрешению. Текущее дерево не очищать/не коммитить целиком ради CI.
2. Чистый GitHub-hosted build новым beta110+; no restored application/native cache.
   `masterdesk-windows.yml` сохраняет build-time payload manifest (все файлы),
   existing inventory, source gate и immutable Actions artifacts.
3. `masterdesk-signing-preflight.yml` принимает только run ID,40hex commit,beta.
   Не принимает EXE/URL/path. GET проверяет repo/head repo, workflow323927768,
   reviewed branch, dispatch, success/completed, attempt1, exact names/run/hash,
   nonexpired archives и root tree gitlink. Download action требует digest-match.
4. `preflight.py` проверяет clean source gate, manifest, все файлы и expected
   gitlink из независимого API tree. В CI trust anchor — authenticated API и
   digest архивов, не самосогласованный JSON внутри ZIP.
5. Только затем отдельная Foundation activation/review и hosted signing chain.
   Локальный manifest и synthetic test JSON НЕ подтверждают build origin.

По [GitHub connector](https://docs.signpath.io/trusted-build-systems/github),
Foundation использует provider-side origin verification и hosted jobs. Новый
preflight дополняет, но не заменяет connector. Новый CI не запускался/не опубликован.
Нельзя выдавать локальную или PR/fork сборку за hosted release.

## Воспроизводимость

Pinned toolchain/engine/vcpkg и byte inventories проверяемы; bit-for-bit rebuild
NOT_RUN и не обещан. Даты PE/AOT, packer timestamp, compression/toolchain могут
влиять на bytes. Не менять старые outputs ради одинаковых hash. Для подписанных
и неподписанных стадий нужны РАЗНЫЕ manifests/digests; после подписи нельзя
переиспользовать unsigned SHA256. Выходы signature helper/transform verifier
пишутся в новые evidence paths без overwrite.
