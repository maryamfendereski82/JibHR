# JibHR

فضای کار داخلی جیبکارت. یک کد Flutter برای Android، iOS، Windows، macOS و Web، با PostgreSQL و Supabase.

این مخزن به یک پروژه Supabase ریموت وصل نیست. اسکیما، توابع و تست دیتابیس محلی‌اند. تا وقتی `env.json` را نساخته‌اید، برنامه فقط صفحه راه‌اندازی را نشان می‌دهد و هیچ داده ساختگی به‌جای سرور نشان نمی‌دهد.

## همین حالا چه چیزی کار می‌کند

- طراحی دیتابیس، RLS و نوشتن فقط از طریق تابع
- تقویم جلالی و هفته شنبه تا جمعه در PostgreSQL و Flutter
- ورود و خروج چندبازه‌ای، عبور از نیمه‌شب، گزارش روزانه و تکمیلی، تأیید آیتمی، اصلاح حضور
- درخواست مرخصی روزانه و ساعتی، تقویم تیم، ثبت غیبت و اعتراض کارمند
- پروژه، عضویت، دیده شدن، تسک شخصی و پروژه‌ای، تأیید، چک‌لیست، زیرتسک، کانبان، فهرست و تقویم
- اسپرینت و مایلستون هر پروژه، با پیشرفت و تاریخ جلالی
- صندوق اعلان داخل برنامه، با شمارنده نخوانده و باز کردن همان رکورد
- ورود با ایمیل یا نام کاربری از Edge Function، بدون برگرداندن ایمیل به کلاینت
- پوسته فارسی، راست‌به‌چپ، تم روشن و تیره، داشبورد و ثبت حضور

داشبورد، تحلیل و خروجی اکسل و PDF از تابع‌های دیتابیس می‌آیند. آفلاین فقط خواندنی است و نوشتن را صف نمی‌کند. اتصال به Supabase ریموت هنوز انجام نشده و برنامه آماده بهره‌برداری اعلام نمی‌شود.

## اجرا

Flutter 3.44 و Dart 3.12. اجرای کامل محلی در `docs/local-development.md` است.

```powershell
cd e:\FlutterProjects\JibHR
npm install
npx supabase start
flutter pub get
flutter run -d chrome --web-port 7357 --dart-define-from-file=env.json
```

`env.json` را از `env.json.example` بسازید و فقط نشانی محلی، کلید publishable، و `SUPABASE_ENV=local` را بگذارید. کلید service role داخل Flutter نیست. `npx supabase` نسخه پین‌شده در `package-lock.json` است. به پروژه ریموت login یا link نکنید.

ثبت‌نام عمومی باید در پروژه Supabase خاموش باشد. `supabase/config.toml` مقدار `enable_signup = false` را دارد. در داشبورد میزبانی هم همین گزینه را خاموش کنید.

## دیتابیس

مهاجرت‌ها در `supabase/migrations` هستند. تست محلی به Docker و تصویر `postgres:17` نیاز دارد:

```powershell
powershell -File scripts\test-db.ps1
```

`supabase/tests/00_local_auth_stub.sql` فقط برای این Postgres محلی است. آن را روی Supabase میزبانی اجرا نکنید.

بعد از اعمال مهاجرت‌ها، کاربر اول را در Authentication بسازید و `scripts/bootstrap_super_admin.sql` را در SQL editor اجرا کنید. ایمیل داخل اسکریپت را عوض کنید. نام کاربری پیش‌فرض `superadmin` است.

## ساخت

```powershell
flutter build apk
flutter build ios
flutter build windows
flutter build macos
flutter build web
```

نسخه iOS و macOS را روی خود آن سیستم‌عامل بسازید. امضای انتشار در این مخزن نیست.

جزئیات در `docs/` است.
