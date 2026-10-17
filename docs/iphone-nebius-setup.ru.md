# iPhone: подключение к Nebius, сборка и установка

Состояние на 17 октября 2026: backend работает на Nebius, HTTPS-шлюз развёрнут на
`https://api.cyclecomp.site`. Подтверждены health по HTTPS снаружи и на iPhone, отказ 401
без тестового ключа и sign-in HTTP 200 с ключом. Ранее успешный запрос Advisor через
backend подтверждён записью SUCCESS. Локальный конфиг iOS подготовлен пользователем и
передаётся товарищу отдельно. Изменения iOS ещё не собирались и не запускались на телефоне.

Для запуска уже подготовленного checkout начните с [короткого README](../README.md).

## 1. Что позволяет текущая техника

Проверено локально: MacBookPro14,3 (MacBook Pro 2017), Intel, macOS 13.7.8; выбран только
`/Library/Developer/CommandLineTools`, полного Xcode в `/Applications` нет.
Телефон по сообщению пользователя — iPhone 15 Pro с iOS 27. Есть Mac товарища, на котором
проект уже запускали в simulator; версия его Xcode пока неизвестна. Платной подписки
Apple Developer Program нет.

Проект использует Swift 6 и локальный пакет с `swift-tools-version: 6.0`, минимум iOS 17.
На Ventura доступен Xcode 15.2 со Swift 5.9, что не подходит для текущего проекта.
Для локальной отладки телефона с iOS 27 выбирайте Xcode с поддержкой этой версии iOS;
Xcode 27 требует macOS Tahoe 26.6 или новее. Mac 2017 не входит даже в официальный список
поддержки Sonoma. Установка старого Xcode не устраняет эти ограничения.

Источники: [таблица Xcode](https://developer.apple.com/xcode/system-requirements),
[модели MacBook Pro](https://support.apple.com/en-ie/108052),
[совместимость Sonoma](https://support.apple.com/en-us/105113).

Выбранный путь: подготовить код на текущем Mac → получить изменения на Mac товарища →
собрать и подписать приложение в Xcode → установить на подключённый iPhone по USB.
Запуск в simulator у товарища ещё не подтверждает поддержку физического iPhone с iOS 27.

## 2. Проверить Mac товарища

Попросите товарища выполнить только диагностику:

```bash
sw_vers
xcodebuild -version
```

Нужны Xcode с поддержкой iOS 27 и подходящая macOS. Если установлен старый Xcode, сначала
проверьте возможность обновления по таблице Apple. Для этого способа не нужны TestFlight,
облачная сборка или покупка нового Mac.

Бесплатный Apple Account/Personal Team позволяет запускать приложение из Xcode на своём
устройстве. Provisioning profile действует 7 дней, затем приложение нужно собрать и
установить снова. См. [Apple Developer account](https://developer.apple.com/help/account/basics/about-your-developer-account).
Можно использовать Personal Team товарища для согласованного личного теста либо добавить
свой Apple Account самостоятельно в Xcode. Пароли и коды подтверждения не передавайте.

## 3. Подготовить доступный HTTPS backend

Для текущего теста адрес уже настроен: `https://api.cyclecomp.site`. Товарищу достаточно
присланного локального конфига, доступ к VM и повторная настройка DNS не требуются.
Порт 8080 остаётся loopback-only на VM. SSH-туннель для телефона не нужен.
Для отдельного развёртывания есть [инструкция DNS и HTTPS](../../cycling-companion-backend/docs/https-domain-setup.ru.md).

## 4. Настройки приложения

Все HTTP-клиенты используют один адрес и общий AuthStubClient/LazySignIn. При сборке задайте:

| Build setting | Значение |
|---|---|
| `CC_BACKEND_BASE_URL` | HTTPS origin: схема и домен, без `/api/v1`, query и пароля |
| `CC_DEMO_ACCESS_TOKEN` | Отдельный ключ Caddy, совпадающий с конфигурацией VM |

Настройки записываются в Info.plist приложения. Поэтому они действуют при запуске иконкой
с Home Screen, а не только из Xcode. Смена адреса или ключа требует новой сборки.
Для simulator сохранён `http://localhost:8080` через локальный backend или SSH-туннель.
На физическом iPhone loopback, удалённый HTTP, неправильный адрес и отсутствующий demo-ключ
показывают экран ошибки конфигурации вместо сетевых запросов к неправильному серверу.
ATS не отключается; `NEBIUS_API_KEY` в приложении отсутствует.

Для текущего теста положите присланный `Backend.local.xcconfig` в папку `Config/` iOS-репозитория.
Не заменяйте его примером и не редактируйте домен/ключ: они уже заполнены.

Только для новой ручной настройки, если готовый файл не передан:

```bash
cp Config/Backend.local.xcconfig.example Config/Backend.local.xcconfig
```

В `Config/Backend.local.xcconfig` укажите фактический домен (для текущего теста —
`api.cyclecomp.site`) и замените `CHANGE_ME_SEPARATE_DEMO_GATEWAY_KEY` на demo-ключ Caddy. Выражения `$(CC_URL_SLASH)`
сохраните: они дают `/`, не создавая комментарий `//` внутри xcconfig.
Файл исключён из Git. Приватный ключ Nebius и SSH-ключ VM товарищу для сборки не нужны.
Не записывайте demo-ключ в отслеживаемые `project.yml`, Info.plist или `project.pbxproj`.

`Config/Backend.xcconfig` подключён к Debug и Release и включает локальный файл, если он
существует. `project.yml` описывает ту же конфигурацию, поэтому генерация проекта её сохраняет.
Переменная окружения Scheme сама по себе не меняет установленную сборку: настройки должны
попасть в plist при сборке. Настройки target в Xcode, если их ранее меняли вручную,
могут иметь приоритет над xcconfig — проверьте итоговые User-Defined build settings.

`AdvisorClient` подключён к Start Ride, Resume и Demo Mode через общий `makeTrackerAndSession`.
Его дедлайн 8 секунд считается по реальному времени, даже если Demo Mode ускорен.
Ошибка сети, 401/502 или таймаут всё ещё переводят сессию на LocalAdvisor; наличие обычного
уведомления само по себе не доказывает ответ NVIDIA.

## 5. Собрать и установить с Mac товарища

1. Получите подготовленные коммиты iOS-репозитория. Если изменения только локальные и ещё
   не отправлены в remote, товарищ их не получит обычным pull: сначала согласуйте push
   или передайте checkout отдельно. Рабочие изменения товарища перед обновлением сохраните.
2. Положите присланный локальный xcconfig в `Config/`. Сначала проверьте health домена
   в Safari на самом iPhone.
3. Откройте `CyclingCompanion.xcodeproj`. Проект уже обновлён; `xcodegen generate` нужен
   только если товарищ использует генерацию из `project.yml` по своему обычному процессу.
4. В Xcode → Settings → Accounts добавьте Apple Account для Personal Team, если его ещё нет.
5. Target CyclingCompanion → Signing & Capabilities: включите Automatically manage signing
   и выберите Team. Если bundle identifier `com.cyclingcompanion.app` недоступен команде,
   задайте уникальный идентификатор для этой тестовой сборки. Личные signing-настройки
   не включайте в общий коммит.
6. Подключите разблокированный iPhone кабелем. Подтвердите Trust на телефоне и Mac.
7. Включите Developer Mode: Settings → Privacy & Security → Developer Mode. Если пункт
   ещё не появился, сначала сопрягите телефон с Xcode. Следуйте запросу перезапуска.
8. В списке run destinations выберите **физический iPhone**, а не simulator. Откройте
   Product → Scheme → Edit Scheme → Run и оставьте Build Configuration = Debug.
9. Product → Test (⌘U) запустит тесты; для приложения затем нажмите Run (⌘R).
   При запросе доверия developer profile выполните указания на iPhone в
   Settings → General → VPN & Device Management.
10. После успешного запуска отключите USB и откройте приложение иконкой. HTTPS-доступ
    должен работать самостоятельно через Wi-Fi и мобильную сеть, пока действует подпись.

Официальные инструкции: [запуск на устройстве](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices),
[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## 6. Проверить приложение на телефоне

1. Импортируйте реальный GPX через Files; дождитесь готовности коридора.
2. Для первого теста нажмите Start Ride, разрешите геолокацию. Для фона проверьте Always.
3. В Debug-сборке доступен Demo Mode. Он использует текущий импортированный маршрут;
   bundled replay не гарантирует совпадение с произвольным GPX. Для теста выбирайте
   совместимый маршрут, иначе кандидаты остановок и map matching могут отсутствовать.
4. Первое подходящее уведомление запросит разрешение на notifications. Без кандидатов
   впереди remote Advisor не вызывается; Force Check ускоряет цикл, но не отменяет это условие.
5. Завершите поездку через Finish Ride и проверьте загрузку на backend.

На VM можно читать свежие trace без секретов:

```bash
cc_compose exec -T postgres psql -U cycling_companion -d cycling_companion \
  -c 'SELECT ride_id, outcome, retrieved_ride_ids, retrieved_snapshot_ids, created_at FROM advisor_trace ORDER BY created_at DESC LIMIT 5;'
```

Сопоставьте время и ride ID с тестом на телефоне; старый synthetic smoke trace не является
новым подтверждением. Нужен новый `SUCCESS`, а для RAG — реальные непустые retrieved IDs
после накопления истории. Сервер может успеть записать SUCCESS уже после клиентского
8-секундного дедлайна: такой trace ещё не доказывает использование ответа приложением.

Логи приложения `Remote Advisor decision` помогают отличить ответ backend от fallback.
Полный сценарий — [full-app walkthrough](manual-testing/full-app-walkthrough.md).

Альтернатива на будущее: облачный Mac/Codemagic → TestFlight потребует платной Apple
Developer Program, distribution signing и App Store Connect. Эта альтернатива не нужна
для выбранного личного теста через Mac товарища; workflow публикации не добавлен.

## 7. Проверки исходников и пределы текущей готовности

Перед сборкой на совместимом Mac или облачном runner проверьте Xcode scheme CyclingCompanion
через Product → Test (⌘U), затем выполните Run или Archive для нужной платформы.
Из терминала доступен `xcodebuild test -project CyclingCompanion.xcodeproj -scheme CyclingCompanion -destination '<фактический simulator destination>'`.
Выберите установленное устройство/runtime из `xcodebuild -showdestinations -project CyclingCompanion.xcodeproj -scheme CyclingCompanion`.

Сборка и тесты в этой сессии не запускались. Синтаксическая проверка plist/YAML/ссылок не
подтверждает компиляцию Swift, signing, установку или работу на реальном iPhone.
