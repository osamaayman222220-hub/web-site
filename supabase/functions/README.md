# أسرار دوال الحافة (Edge Functions Secrets Guide) — CareNest

يوضح هذا الدليل جميع الأسرار ومتغيرات البيئة المطلوبة لتشغيل دوال الحافة (Edge Functions) الخاصة بمنصة CareNest على مشروع Supabase (`tfolrgauojmbeofartaq`).

---

## 1. جدول الأسرار حسب الدوال

| الدالة | المتغير السري | الوصف والغرض | كيفية التوليد / المصدر |
|:---|:---|:---|:---|
| **مشترك لجميع الدوال** | `ALLOWED_ORIGINS` | النطاقات المصرح لها بالاتصال عبر CORS (مثل `https://carenest.app,https://carenest.eg,https://osamaayman222220-hub.github.io`) | النطاق الرسمي للإنتاج |
| **save-national-id**<br>**get-national-id** | `NATIONAL_ID_ENCRYPTION_KEY` | مفتاح تشفير وفك تشفير الرقم القومي بخوارزمية AES-256-GCM (32 بايت / 64 hex) | `openssl rand -hex 32` |
| **save-national-id**<br>**get-national-id** | `NATIONAL_ID_SALT` | ملح تشفير HMAC-SHA256 لبصمة الرقم القومي السريعة لمنع التكرار | `openssl rand -base64 32` |
| **export-carenest-data** | `CARENEST_EXPORT_TOKEN` | التوكن السري لتصدير البيانات إلى Excel Power Query (Fail-Closed) | `openssl rand -base64 32` |
| **excel-sync** | `EXCEL_SYNC_SECRET` | سر مصادقة Webhook المتصل بقاعدة البيانات (Constant-Time-Style Verification) | `openssl rand -base64 32` |
| **excel-sync** | `AZURE_CLIENT_ID` | معرّف تطبيق Microsoft Azure Active Directory لمزامنة OneDrive | من لوحة Azure App Registrations |
| **excel-sync** | `AZURE_CLIENT_SECRET` | كلمة سر تطبيق Azure المسجل | من لوحة Azure App Registrations |
| **excel-sync** | `MS_REFRESH_TOKEN` | رمز التحديث طويل الأمد لحساب Microsoft Graph API | ناتج عملية مصادقة OAuth2 |
| **excel-sync** | `EXCEL_FILE_ID` | معرف ملف Excel المستهدف على OneDrive | من رابط ملف OneDrive |

> [!NOTE]
> المتغيرات التالية يتم تعيينها تلقائياً بواسطة منصة Supabase ولا تحتاج لضبط يدوي:
> - `SUPABASE_URL`
> - `SUPABASE_ANON_KEY`
> - `SUPABASE_SERVICE_ROLE_KEY`

---

## 2. توليد الأسرار العشوائية القوية

لتوليد قيم تشفير قوية جداً من الطرفية:

```bash
# توليد مفتاح تشفير الرقم القومي (64 hex characters / 32 bytes):
openssl rand -hex 32

# توليد مفتاح ملح الهاش وتوكن التصدير وسر الويب هوك:
openssl rand -base64 32
```

---

## 3. أوامر ضبط الأسرار عبر Supabase CLI

قم باستبدال `<ضع القيمة هنا>` بالقيم الحقيقية ثم نفذ الأوامر التالية:

```bash
# 1. أسرار الرقم القومي و CORS
supabase secrets set --project-ref tfolrgauojmbeofartaq \
  ALLOWED_ORIGINS="https://carenest.app,https://carenest.eg,https://osamaayman222220-hub.github.io" \
  NATIONAL_ID_ENCRYPTION_KEY="<ضع_مفتاح_AES_الناتج_من_hex_32_هنا>" \
  NATIONAL_ID_SALT="<ضع_ملح_الهاش_هنا>"

# 2. سر تصدير بيانات CareNest لـ Power Query
supabase secrets set --project-ref tfolrgauojmbeofartaq \
  CARENEST_EXPORT_TOKEN="<ضع_توكن_التصدير_القوي_هنا>"

# 3. أسرار مزامنة OneDrive و Excel Webhook
supabase secrets set --project-ref tfolrgauojmbeofartaq \
  EXCEL_SYNC_SECRET="<ضع_سر_الويب_هوك_هنا>" \
  AZURE_CLIENT_ID="<ضع_معرف_تطبيق_AZURE_هنا>" \
  AZURE_CLIENT_SECRET="<ضع_سر_تطبيق_AZURE_هنا>" \
  MS_REFRESH_TOKEN="<ضع_رمز_التحديث_هنا>" \
  EXCEL_FILE_ID="<ضع_معرف_ملف_الاكسل_هنا>"
```

---

## 4. سكريبت نشر دوال الحافة (Deployment Script)

يمكنك نشر جميع الدوال دفعة واحدة بتشغيل سكريبت `deploy.sh` أو تنفيذ الأوامر التالية:

```bash
supabase functions deploy save-national-id --project-ref tfolrgauojmbeofartaq --no-verify-jwt
supabase functions deploy get-national-id --project-ref tfolrgauojmbeofartaq --no-verify-jwt
supabase functions deploy verify-visit-code --project-ref tfolrgauojmbeofartaq --no-verify-jwt
supabase functions deploy excel-sync --project-ref tfolrgauojmbeofartaq --no-verify-jwt
supabase functions deploy export-carenest-data --project-ref tfolrgauojmbeofartaq --no-verify-jwt
```

