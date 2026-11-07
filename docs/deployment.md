# استقرار

پروژه ریموت در این محیط ساخته و تست نشده است. قدم‌ها در `remote-supabase.md` است. تا اتصال واقعی و آزمون نقش‌ها برقرار نشده، فرض نکنید دیتابیس آماده است.

## Supabase

1. یک پروژه بسازید.
2. SQL مهاجرت‌ها را به ترتیب نام در SQL editor اجرا کنید. فایل `00_local_auth_stub.sql` را اجرا نکنید.
3. Authentication را روی ایمیل و رمز بگذارید. ثبت‌نام را خاموش کنید. MFA و ورود پیامکی را روشن نکنید.
4. عمر لینک دعوت ایمیل را بلند کنید. ردیف دعوت ۷ روز معتبر است، ولی لینک پیش‌فرض Auth کوتاه‌تر است.
5. رازها را فقط در Edge Function بگذارید: `SUPABASE_URL`، `SUPABASE_ANON_KEY` یا `SUPABASE_PUBLISHABLE_KEY`، `SUPABASE_SERVICE_ROLE_KEY` یا `SUPABASE_SECRET_KEY`، و `SITE_URL`.
6. تابع‌ها را مستقر کنید. `login` باید `verify_jwt = false` باشد چون کاربر هنوز توکن ندارد. بقیه تابع‌ها JWT را چک می‌کنند.
7. کاربر اول را در داشبورد بسازید و `scripts/bootstrap_super_admin.sql` را با ایمیل همان کاربر اجرا کنید.
8. یک بار با نام کاربری `superadmin` از برنامه وارد شوید.

زمان‌بندی `submit_due_attendance_reports` را با Supabase Scheduled Function یا `pg_cron` بگذارید و فقط با کلید سرویس صدا بزنید. روزی یک بار بعد از نیمه‌شب تهران کافی است. اجرای اضافه بی‌اثر است.

## کلاینت

`env.json` را از روی `env.json.example` بسازید. آن فایل را کامیت نکنید.

```powershell
flutter build web --dart-define-from-file=env.json
flutter build apk --dart-define-from-file=env.json
flutter build windows --dart-define-from-file=env.json
```

`flutter build ios` و `flutter build macos` روی macOS اجرا می‌شوند.

## پلن رایگان Supabase

پلن رایگان سقف حجم دیتابیس، تعداد اتصال، و مدت نگهداری پشتیبان خودکار دارد. حضور و غیاب داده سازمانی است و پشتیبان خودکار پلن رایگان برای بازیابی بلندمدت کافی نیست. روش نسخه پشتیبان مستقل در `backup-restore.md` است. صندوق اعلان به جدول `notifications` در انتشار `supabase_realtime` اشتراک می‌کند و فقط ردیف گیرنده جاری را می‌گیرد. پایگاه آزمون محلی این انتشار را ندارد.
