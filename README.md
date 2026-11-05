# Cab для Android (Flutter)

Мобільний клієнт чату Cab у стилі Windows 98. Працює з вашим сервером
`https://yurist1606.pythonanywhere.com`, сервер змінювати не потрібно.
Адреса сервера — константа `serverUrl` на початку `lib/main.dart`.

## Спосіб А. Без встановлення чогось на комп'ютер (безкоштовно)

APK збирає безкоштовна хмара GitHub Actions.

1. Створіть безкоштовний акаунт на github.com.
2. Створіть новий репозиторій (наприклад, `cab-mobile`) і завантажте в нього
   **вміст** цієї папки: `pubspec.yaml`, `lib/main.dart`, `.gitignore`
   і папку `.github` (кнопка *Add file → Upload files*; папку `.github`
   перетягніть цілком).
3. Відкрийте вкладку **Actions**. Збірка запуститься сама (або натисніть
   *Build Android APK → Run workflow*). Триває 5–10 хвилин.
4. Коли з'явиться зелена галочка, відкрийте цей запуск і внизу, в розділі
   **Artifacts**, завантажте `Cab-apk` (це zip із файлом `app-release.apk`).

## Спосіб Б. Збірка на власному комп'ютері

1. Встановіть Flutter SDK (flutter.dev) і Android Studio (потрібні Android SDK).
2. У цій папці виконайте:

       flutter create --platforms=android --project-name cab --org com.cab.chat .
       flutter pub get

3. Відкрийте `android/app/src/main/AndroidManifest.xml` і додайте перед
   `<application`:

       <uses-permission android:name="android.permission.INTERNET"/>

   Без цього рядка release-збірка не матиме доступу до інтернету.
4. Запустіть `flutter build apk --release`. Файл буде тут:
   `build/app/outputs/flutter-apk/app-release.apk`.
   Для швидкої перевірки з телефона на кабелі: `flutter run`.

## Встановлення на телефон

1. Перекиньте `app-release.apk` на телефон (месенджер, пошта, кабель).
2. Відкрийте файл. Android попросить дозволити встановлення з цього джерела,
   погодьтеся.
3. Запустіть Cab і введіть нікнейм.

Друзям надсилайте той самий APK.

## Обмеження

- Опитування сервера працює, лише поки застосунок відкритий. У фоні Android
  може його зупинити, але після повернення чат сам перепідключається.
- Push-сповіщень немає: для них потрібен Firebase і зміни на сервері.
- iOS: безкоштовно зібрати й поширити застосунок не вийде. Потрібен Mac із Xcode
  (встановлення на власний iPhone із безкоштовним Apple ID живе 7 днів),
  а TestFlight або App Store вимагають Apple Developer за 99 $/рік.
