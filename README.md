# Cycling Companion — запуск на iPhone

iOS-приложение для сопровождения велосипедной поездки: импорт GPX, карта маршрута,
отслеживание прогресса и рекомендации остановок через backend Nebius с локальным fallback.

Для первого запуска используется **`https://api.cyclecomp.site`**. Подключение backend,
TLS, health на iPhone и sign-in с тестовым ключом подтверждены 17 октября 2026.
Сборка текущих изменений iOS и запуск на физическом устройстве ещё требуют проверки.

## 1. Обновить ветку

В папке **cycling-companion-ios** проверьте рабочие изменения:

```bash
git status --short
```

Если вывод не пустой, сначала сохраните свои изменения. Затем:

```bash
git switch main
git pull --ff-only
```

## 2. Положить присланный конфиг

Получите `Backend.local.xcconfig` отдельно от владельца backend и положите его сюда:

```text
cycling-companion-ios/
  Config/
    Backend.xcconfig
    Backend.local.xcconfig  ← присланный файл
```

Файл уже содержит домен и отдельный тестовый ключ. Редактировать Swift, Info.plist или
настройки backend не требуется. Локальный конфиг исключён из Git; не публикуйте его.
Проверьте путь, не печатая содержимое:

```bash
test -f Config/Backend.local.xcconfig && echo "Конфиг на месте"
git check-ignore Config/Backend.local.xcconfig
```

`Config/Backend.local.xcconfig.example` — только пример для ручной настройки.
Не копируйте его поверх уже присланного заполненного файла.

## 3. Открыть проект и выбрать подпись

Нужен полный Xcode со Swift 6 и поддержкой версии iOS телефона. Для iPhone с iOS 27
используйте Xcode с поддержкой iOS 27; системные требования — в
[таблице Apple](https://developer.apple.com/xcode/system-requirements).

```bash
open CyclingCompanion.xcodeproj
```

Готовый Xcode-проект и общая схема `CyclingCompanion` сохранены в репозитории.
Для обычного запуска регенерация через XcodeGen не нужна. Если используете XcodeGen в
своём процессе, `project.yml` содержит те же настройки и сохраняет подключение конфига.

В Xcode:

1. При необходимости добавьте Apple Account в **Xcode → Settings → Accounts**.
2. Выберите target **CyclingCompanion → Signing & Capabilities**.
3. **Automatically manage signing** включено проектом; выберите свой **Team**.
4. Если Xcode сообщает, что Bundle Identifier занят или недоступен Team, задайте уникальный
   идентификатор для своей тестовой установки. Персональные signing-изменения оставьте локально.

Для личного запуска через Xcode подходит бесплатный Personal Team. Подпись действует
7 дней, затем нужна повторная установка из Xcode.
[Условия Apple](https://developer.apple.com/help/account/basics/about-your-developer-account).

## 4. Запустить на телефоне

1. Подключите разблокированный iPhone кабелем и подтвердите **Trust**.
2. Включите **Settings → Privacy & Security → Developer Mode**, если Xcode запросит это;
   выполните перезапуск и подтверждение на телефоне.
3. Выберите схему **CyclingCompanion** и физический iPhone в run destinations.
   Общая схема запуска использует **Debug**, поэтому Demo Mode включён.
4. Нажмите **Run (⌘R)**. При запросе доверия developer profile следуйте указаниям телефона.
5. После первого запуска отключите USB и откройте приложение иконкой: адрес и ключ
   встроены в собранное приложение и не зависят от подключения к Mac.

Для первого сценария импортируйте реальный GPX через **Choose GPX File**, дождитесь коридора
и начните поездку. Разрешите геолокацию; уведомления запрашиваются при первой подходящей
рекомендации. Для Debug replay используйте Demo Mode с совместимым маршрутом.

При проблемах с сетью откройте на iPhone:
[health backend](https://api.cyclecomp.site/actuator/health) — ожидается `"status":"UP"`.
Если показан экран **Backend configuration required**, проверьте путь локального конфига
и пересоберите приложение. Полный разбор — в
[инструкции подключения и установки](docs/iphone-nebius-setup.ru.md).

Для проверки исходников запустите **Product → Test (⌘U)** на доступном simulator.
Успешный health или локальное уведомление сами по себе не подтверждают, что приложение
успело получить решение NVIDIA: отличайте `Remote Advisor decision` от local fallback
по логам. Дальнейший сценарий — [full-app walkthrough](docs/manual-testing/full-app-walkthrough.md).
