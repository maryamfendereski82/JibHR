# پشتیبان و بازیابی

پشتیبان داشبورد Supabase به پلن پروژه وابسته است و روی پلن رایگان نگهداری کوتاهی دارد. برای حضور و غیاب یک نسخه مستقل لازم است.

## گرفتن نسخه

دستور را جایی اجرا کنید که کلید دیتابیس فقط در محیط همان ماشین است. خروجی را در مخزن نگذارید.

```powershell
pg_dump --format=custom --no-owner --dbname "$DATABASE_URL" --file "jibhr-YYYYMMDD.dump"
```

`DATABASE_URL` رشته اتصال Postgres است، نه کلید anon. هفته‌ای یک بار، و قبل از هر `supabase db push`، کافی است اگر حجم کم باشد. فایل را خارج از سرور برنامه و خارج از مخزن نگه دارید. هشت نسخه هفتگی را نگه دارید و قدیمی‌تر را پاک کنید.

```powershell
$env:DATABASE_URL = "postgresql://..."
powershell -File scripts\backup.ps1
```

روی این ویندوز `pg_dump` نصب نیست. آزمون بازیابی با `pg_dump` و `pg_restore` داخل کانتینر PostgreSQL 17 انجام شد: پایگاه مقصد ساخته شد، شمار `profiles` و `attendance_intervals` با مبدأ برابر بود، و پایگاه مقصد بعد از مقایسه حذف شد. این آزمون جای پشتیبان پروژه ریموت را نمی‌گیرد.

این دستور اسکیمای `auth` را هم می‌گیرد. برای بازیابی کامل لازم است. اگر فقط داده برنامه را می‌خواهید، `--schema=public --schema=app` را اضافه کنید و بدانید حساب‌های Auth جدا می‌مانند.

## بازیابی

بازیابی را اول روی یک پروژه خالی تمرین کنید.

```powershell
pg_restore --no-owner --dbname "$TARGET_DATABASE_URL" jibhr-YYYYMMDD.dump
```

بعد از بازیابی، یک ورود آزمایشی و یک جمع کارکرد تأییدشده را با عدد قبل از نسخه مقایسه کنید. گزارش تأییدشده نباید در عملیات عادی حذف شده باشد. اگر ردیفی کم بود، بازیابی ناقص است.

## آنچه نسخه باید حفظ کند

- `attendance_intervals` با زمان اصلی و مؤثر
- `attendance_events`
- `attendance_daily_segments` و `superseded_at`
- `attendance_daily_reports` و آیتم‌های تصمیم
- `attendance_corrections`
- `audit_logs`، از جمله رویداد `report.export`. خود فایل اکسل و PDF ذخیره نمی‌شود.

بازگرداندن فقط جدول پروفایل بدون این جدول‌ها سابقه کارکرد را از بین می‌برد.
