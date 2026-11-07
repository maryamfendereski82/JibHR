# اجرای محلی

این مسیر فقط Supabase محلی است. `supabase login` و `supabase link` را نزنید. کانتینرهای `jibhr-pg-test`، `ronagh-api` و `ronagh-postgres` را متوقف یا حذف نکنید.

## ابزار

Node.js 20 یا جدیدتر و Docker Desktop لازم است. CLI داخل پروژه پین شده است و با `npx supabase` اجرا می‌شود. نسخه فعلی `3.0.0` است و در `package-lock.json` ثبت شده است.

```powershell
cd E:\FlutterProjects\JibHR
npm install
npx supabase start
```

`npx supabase stop` فقط کانتینرهای همین پروژه را می‌خواباند و حجم پایگاه را نگه می‌دارد. `--no-backup` را نزنید.

## درگاه‌ها

| خدمت | نشانی |
|---|---|
| API | http://127.0.0.1:54321 |
| Studio | http://127.0.0.1:54323 |
| پایگاه | 127.0.0.1:54322 |
| نامه آزمایشی | http://127.0.0.1:54324 |
| برنامه Flutter | http://127.0.0.1:7357 |

پورت 54329 برای کانتینر آزمون `jibhr-pg-test` مانده است. Pooler محلی روی 55429 تنظیم شده و خاموش است. `site_url` برنامه `http://localhost:7357` است، نه پورت 8080.

## مهاجرت

`npx supabase start` فایل‌های `supabase/migrations` را به ترتیب نام روی پایگاه Supabase محلی اعمال می‌کند. `supabase/tests/00_local_auth_stub.sql` فقط برای `scripts/test-db.ps1` است. آن را روی این پشته اجرا نکنید. Supabase محلی جدول و نقش Auth خودش را دارد.

بعد از بالا آمدن، این‌ها در پایگاه `postgres` وجود دارند: جدول‌های `public`، سیاست RLS، تابع‌های `public`، ایندکس‌ها، و جدول `notifications` داخل publication به نام `supabase_realtime`.

## رازها

Flutter فقط `env.json` را می‌خواند: نشانی API، کلید publishable، و `SUPABASE_ENV=local`. این فایل در gitignore است.

کلید سرویس را CLI خودش به کانتینر Edge Function می‌دهد. آن را در `env.json` نگذارید. `supabase/functions/.env` فقط `SITE_URL` و `ALLOWED_ORIGIN` محلی را دارد و کامیت نمی‌شود. `npx supabase secrets set` به پروژه ریموت وصل می‌شود و اینجا استفاده نمی‌شود.

ثبت‌نام عمومی خاموش است. `login` بدون JWT صدا زده می‌شود. بقیه تابع‌ها JWT می‌خواهند.

## سوپر ادمین

کاربر Auth را یک بار بسازید، ایمیل را تأیید کنید، و `scripts/bootstrap_super_admin.sql` را با همان ایمیل روی پایگاه محلی اجرا کنید. اسکریپت اگر پروفایل وجود داشته باشد خطا می‌دهد و رمز را ذخیره نمی‌کند.

روی این ماشین یک حساب دورریختنی ساخته شده است. نام کاربری `superadmin` است. ایمیل و رمز در `.local/admin.txt` است. آن فایل را کامیت نکنید.

## برنامه

```powershell
flutter run -d chrome --web-port 7357 --dart-define-from-file=env.json
```

اگر Chrome درگیر دیباگر دیگری است، همین برنامه با `flutter run -d web-server --web-hostname 127.0.0.1 --web-port 7357 --dart-define-from-file=env.json` روی همان نشانی بالا می‌آید.

نسخهٔ Debug با `web-server` در Chrome بدون رابط اجرا نشد و صفحه بدون خطا خالی ماند. اگر به مرورگر خودکار نیاز دارید، `--release` را هم اضافه کنید. برای دیدن تغییر تازه، سرور را دوباره اجرا کنید.

برای ورود، برنامه را از `http://localhost:7357` باز کنید. تابع `login` فقط همین Origin را می‌پذیرد.

صفحه ساخت کارمند در Flutter نیست. ساخت کارمند از تابع `create-employee` انجام می‌شود.
