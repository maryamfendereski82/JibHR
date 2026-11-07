# Supabase ریموت

این محیط به پروژه ریموت وصل نشده و فرمان `supabase` روی این ویندوز نصب نیست. دستورهای زیر را وقتی مرجع پروژه و توکن دسترسی را دارید اجرا کنید. دیتابیس ریموت را برای سبز شدن مهاجرت reset نکنید.

## متغیرها

Flutter فقط این سه مقدار را از `env.json` می‌گیرد:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_ENV` با مقدار `local` یا `staging` یا `production`

اگر محیط `production` نباشد، نام محیط بالای پوسته دیده می‌شود. کلید service role فقط در راز Edge Function است. نمونه نام‌ها در `.env.example` و `env.json.example` است. هر دو فایل واقعی در `.gitignore` هستند.

## استقرار

1. `supabase login`
2. `supabase link --project-ref YOUR_REF`
3. `supabase migration list` و مقایسه با `supabase/migrations`
4. اگر تاریخچه ریموت با محلی فرق دارد یا مهاجرتی داده را پاک می‌کند، متوقف شوید و اختلاف را بنویسید.
5. قبل از اعمال، `scripts/backup.ps1` را با `DATABASE_URL` اجرا کنید.
6. `supabase db push`
7. رازهای تابع را با `supabase secrets set` بگذارید، نه در کلاینت.
8. `supabase functions deploy login` با `verify_jwt = false`، و بقیه تابع‌ها با JWT.
9. کاربر اول را در Authentication بسازید و `scripts/bootstrap_super_admin.sql` را یک بار، بعد از عوض کردن ایمیل، در SQL editor اجرا کنید. اسکریپت اگر پروفایل وجود داشته باشد خطا می‌دهد و رمز را ذخیره نمی‌کند.

`00_local_auth_stub.sql` را روی میزبان اجرا نکنید. ثبت‌نام عمومی خاموش می‌ماند. MFA و OTP اضافه نشده است.

## انتشار اعلان

جدول `notifications` باید در publication به نام `supabase_realtime` باشد. مهاجرت اعلان این کار را اگر publication وجود داشته باشد انجام می‌دهد. روی پروژه میزبان، Realtime را برای همین جدول روشن کنید.

آزمون نقش‌ها، دعوت، بازیابی رمز و RLS باید با حساب واقعی ریموت انجام شود. تا آن آزمون‌ها سبز نشده‌اند، ریموت آماده نیست.
