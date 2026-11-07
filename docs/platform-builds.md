# ساخت پلتفرم

نام برنامه JibHR است. شعار و امضا در `Fa.tagline` و `Fa.signature` است. برچسب اندروید و نام محصول ویندوز JibHR است.

کلید امضا و گواهی را کامیت نکنید. `*.jks` در gitignore است.

| هدف | میزبان لازم | دستور |
|---|---|---|
| Android APK | Android SDK | `flutter build apk --dart-define-from-file=env.json` |
| Android App Bundle | Android SDK و keystore انتشار | `flutter build appbundle --dart-define-from-file=env.json` |
| Windows | همین ویندوز | `flutter build windows --dart-define-from-file=env.json` |
| Web | همین ویندوز | `flutter build web --dart-define-from-file=env.json` |
| iOS | macOS و Xcode و provisioning | `flutter build ios --dart-define-from-file=env.json` |
| macOS | macOS و امضای اپل | `flutter build macos --dart-define-from-file=env.json` |

این مخزن روی ویندوز است. ساخت iOS و macOS اینجا انجام نشده و تا روی مک ساخته نشود آماده انتشار نیست. وب باید روی HTTPS میزبانی شود و نشانی بازگشت Auth همان میزبان باشد.

## نتیجه همین ویندوز

- `flutter build web --release` ساخته شد: `build/web`. خروجی جاوااسکریپت است. Wasm با `flutter_secure_storage_web` سازگار نیست چون آن بسته `dart:html` دارد.
- `flutter build apk --release` و `flutter build appbundle --release` ساخته شدند: `build/app/outputs/flutter-apk/app-release.apk` و `build/app/outputs/bundle/release/app-release.aab`. هر دو با امضای debug قالب اندروید ساخته شده‌اند، چون keystore انتشار در مخزن نیست. این فایل‌ها برای فروشگاه نیستند.
- کش افزایشی Kotlin بین درایو `C:` (کش pub) و `E:` (پروژه) خطا می‌داد. `kotlin.incremental=false` در `android/gradle.properties` همان خطا را برمی‌دارد.
- Visual Studio و workload سی‌پلاس‌پلاس نصب نیست، پس `flutter build windows` اجرا نشد.
- مجوزهای Android SDK هنوز با `flutter doctor --android-licenses` پذیرفته نشده‌اند. ساخت APK با همین حال تمام شد.

برای انتشار، `SUPABASE_ENV` را `production` بگذارید تا برچسب محیط دیده نشود.
