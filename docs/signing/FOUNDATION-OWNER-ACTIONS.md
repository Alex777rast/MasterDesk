# Что остаётся владельцу / SignPath

## NEEDS_OWNER — сейчас

1. Не публиковать подготовительный пакет как одобренный/подписанный релиз.
2. Подтвердить MFA GitHub и SignPath без отправки recovery codes/секретов.
   API вернул null, не false. Настройки аккаунта автоматически не менялись.
3. По отдельному разрешению включить реальные branch/rulesets и review/checks,
   environment reviewers; сейчас обе исследованные ветки unprotected и
   environments пусты. CODEOWNERS уже описывает чувствительные пути, но не enforcement.
4. Получить надёжное подтверждение licensing для exact default_net/hwcodec/
   impersonate-system revisions и parent scope workspace crates. Не присваивать
   отсутствующую лицензию самостоятельно. Проверить native codecs/assets/fonts,
   custom engine source и corresponding source каждого release.
5. Согласовать с Foundation публичный fork/подписываемую upstream branch и
   modified desktop_drop, proposed owned3/outer scope. Сейчас approvedScope=[]
   исключает ВСЕ неоднозначные компоненты из automatic signing.
6. Объяснить Foundation будущие Free/Pro500р/месяц/hosted-service планы, при
   сохранении AGPL исходников/прав. Не считать ни автоматическим отказом, ни
   заранее разрешённым commercial dual-license. Правовой вывод требует review.
7. Отдельно разрешить source-only push/PR после просмотра new helper commits и
   полного источника будущего candidate. Никакого push/main change сейчас нет.

## BLOCKED — SignPath

- Одобрение проекта и сертификат: есть только прежнее подтверждение receipt.
- Organization/project/policy/artifact configuration IDs; provider-side origin
  rules, approver roles, certificate subject/SHA256 pin.
- Допуск payload-first→custom portable repack→outer signing; CI template не
  заменяет provider validation. Возможны дополнительные требования.

## После approval

Следовать [runbook](SIGNING-RUNBOOK.md), не просто заменить placeholders.
Нужны отдельные разрешения на actual signing, новую сборку/GUI VM acceptance и
на публикацию сайта/релиза. Старые105–109 EXE остаются неизменными.
Владелец вводит minimal submitter token непосредственно в protected environment;
его никогда не нужно присылать Codex в чат.

Prepared [Foundation packet](FOUNDATION-REVIEW-PACKET.md) не отправлен. Он
не содержит персональных контактов, токенов, private deployment files или lab logs.
