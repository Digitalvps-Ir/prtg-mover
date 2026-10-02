<div dir="rtl">

# PRTG Manager — راهنمای فارسی

ابزاری برای **بکاپ، بازگردانی و انتقال سرورهای PRTG Network Monitor** از یک داشبورد تحت وب: کل PRTG، یا فقط تاریخچه، دیوایس‌ها، نوتیفیکیشن‌ها، تریگرها یا لایسنس آن — و همیشه با **پیش‌نمایش**، پیش از آنکه چیزی تغییر کند.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-2563eb)
![Windows Server 2012 R2 – 2025](https://img.shields.io/badge/Windows%20Server-2012%20R2%20%E2%80%93%202025-0078d4)
![No dependencies](https://img.shields.io/badge/dependencies-none-15803d)
![License MIT](https://img.shields.io/badge/license-MIT-lightgrey)

[راهنمای انگلیسی / English README](README.md) · [معماری](docs/ARCHITECTURE.md) · [رفع مشکل](docs/TROUBLESHOOTING.md) · [تغییرات نسخه‌ها](CHANGELOG.md)

> نام این برنامه تا نسخهٔ 1.9 **PRTG Mover** بود. اتصال‌های VPN ویندوز و Routeهای آن‌ها دیگر بخشی از این برنامه نیستند: بکاپ، بازگردانی و انتقال آن‌ها را **VPN Manager** (همان VPN Watch قبلی) انجام می‌دهد. جزئیات در بخش [آمدن از PRTG Mover](#coming-from-prtg-mover).

## <a name="contents"></a>فهرست

- [این ابزار چه کار می‌کند؟](#what-it-does)
- [انواع بکاپ](#backup-types)
- [بازگردانی: اول پیش‌نمایش، Rollback داخلی](#restore-preview-first-rollback-built-in)
- [صفحهٔ لایسنس](#license-page)
- [روش‌های اتصال](#connection-methods)
- [نصب](#installation)
- [شروع سریع: انتقال یک سرور PRTG](#quick-start-migrate-a-prtg-server)
- [داشبورد](#dashboard)
- [خط فرمان](#command-line)
- [ساختار بستهٔ بکاپ (نسخهٔ 2)](#backup-package-format-version-2)
- [امنیت](#security)
- [محدودیت‌ها و چک‌لیست بعد از انتقال](#limitations-and-after-migration-checklist)
- [آمدن از PRTG Mover](#coming-from-prtg-mover)
- [ساختار پروژه](#project-layout)
- [توسعه](#development)

## <a name="what-it-does"></a>این ابزار چه کار می‌کند؟

1. **اول بررسی می‌کند.** هر سرور باید با دسترسی Administrator جواب بدهد و فضای دیسک کافی داشته باشد، و نسخه‌های PRTG هم باید با هم جور باشند. اگر یکی از این بررسی‌ها رد شود، هیچ‌جا چیزی تغییر نمی‌کند. فضای لازم برای بکاپ از روی چیزی تخمین زده می‌شود که واقعاً کپی می‌شود (نه کل پوشهٔ داده با لاگ‌ها و کپی‌های خودکار تنظیمات)؛ اگر فضا کم باشد و تاریخچه بزرگ، پیام خطا بکاپ بدون تاریخچه را پیشنهاد می‌کند.
2. **مبدأ را بدون دست زدن به آن می‌خواند.** PRTG روشن می‌ماند. فایل‌ها از Snapshot ویندوز (VSS) خوانده می‌شوند و بخش‌های تنظیمات از `PRTG Configuration.dat`، بی‌آنکه چیزی نوشته شود. Snapshot بکاپی که شکست بخورد فوراً پاک می‌شود تا درایو سیستم پر نشود.
3. **هر بسته را روی Manager نگه می‌دارد**، همراه با متادیتا، چک‌سام و در صورت تمایل رمز بکاپ — آماده برای Validate، Inspect، دانلود و Restore.
4. **با پیش‌نمایش بازمی‌گرداند.** پیش از هر تغییری دقیقاً می‌بینید چه چیزی ساخته، به‌روز یا رد می‌شود، کجا تداخل هست و چه چیزی کم است.
5. **بعد از کار ثابت می‌کند که PRTG سالم است** (Core و Probe در حال اجرا هستند، رابط وب جواب می‌دهد و ۴۵ ثانیه بعد هم پایدار است) — و اگر نباشد، وضعیت قبلی را خودکار برمی‌گرداند.

همه‌چیز با همان **Windows PowerShell 5.1** خود ویندوز اجرا می‌شود. روی سرورها چیزی نصب نمی‌شود.

## <a name="backup-types"></a>انواع بکاپ

| نوع | محتوا | روی مبدأ |
|---|---|---|
| **Full** | تنظیمات PRTG (همهٔ آبجکت‌ها)، پوشهٔ داده همراه با تاریخچه (اختیاری)، کلون برنامه و سرویس‌های ویندوز، رجیستری، لایسنس، گواهی SSL، سفارشی‌سازی‌ها (سنسورهای سفارشی، اسکریپت‌های نوتیفیکیشن، Lookupها، MIBها، قالب‌های دیوایس، Mapها)، فایل‌های دسکتاپ و مسیرهای اضافه (اختیاری). اگر مقصد هم تیک بخورد، این کار یک مهاجرت است. | Snapshot ویندوز (VSS)؛ PRTG روشن می‌ماند |
| **History** | پوشهٔ `Monitoring Database` — داده‌ای که PRTG گراف‌ها و جدول‌ها را از آن می‌سازد — کامل یا فقط *N* روز آخر، به‌علاوهٔ فهرست دیوایس‌هایی که این داده مال آن‌هاست. | Snapshot (VSS) |
| **Devices** | کل درخت دیوایس‌ها: Probeها، گروه‌ها، دیوایس‌ها، سنسورها با همهٔ تنظیمات، کانال‌ها و تریگرهایشان، و سلسله‌مراتب. | فقط خواندن |
| **Notifications** | قالب‌های نوتیفیکیشن (ایمیل، Push، SMS، HTTP، اجرای برنامه، Syslog، SNMP Trap، Teams، Slack و…) و Scheduleهایی که این قالب‌ها به کار می‌برند. | فقط خواندن |
| **Triggers** | همهٔ تریگرها (State، Threshold، Speed، Volume، Change) روی همهٔ Probeها، گروه‌ها، دیوایس‌ها و سنسورها، همراه با آبجکتی که هر تریگر به آن تعلق دارد. | فقط خواندن |
| **License** | نام لایسنس، کلید، اطلاعات فعال‌سازی و فایل‌های لایسنس — **همیشه روی خود سرور** با رمز بکاپ رمزگذاری می‌شود؛ کلید هیچ‌وقت به‌صورت متن ساده جابه‌جا یا ذخیره نمی‌شود. | فقط خواندن |

فقط چیزی بسته‌بندی می‌شود که PRTG واقعاً لازم دارد: فایل‌های لاگ، کش‌ها (`PRTG Graph Data Cache*`)، فایل‌های موقت و کپی‌های خودکار قدیمی تنظیمات برداشته نمی‌شوند، مگر اینکه خودتان بخواهید.

هر بسته را می‌توان **با رمز بکاپ رمزگذاری کرد** (AES-256-CBC + HMAC-SHA256؛ کلید با PBKDF2-SHA256 و ۲۰۰٬۰۰۰ دور ساخته می‌شود). رمز اشتباه یا فایلی که دست خورده باشد، پیش از رمزگشایی یا بازگردانی هر چیزی تشخیص داده می‌شود.

## <a name="restore-preview-first-rollback-built-in"></a>بازگردانی: اول پیش‌نمایش، Rollback داخلی

در صفحهٔ **Backups** هر بسته دکمهٔ **Restore…** دارد. پنجرهٔ بازگردانی مقصد (یا مقصدها) و گزینه‌ها را می‌پرسد، سپس **Preview** مقصد را می‌خواند (بدون هیچ تغییری) و این‌ها را نشان می‌دهد:

| | Full | History | Devices / Notifications / Triggers | License |
|---|---|---|---|---|
| آیتم‌هایی که ساخته / به‌روز / رد می‌شوند | تنظیمات، پوشهٔ داده، لایسنس، رجیستری، سفارشی‌سازی‌ها | فایل‌های جدید، فایل‌هایی که از قبل هستند | هر آبجکت با کاری که رویش انجام می‌شود و دلیل آن | لایسنس فعلی ← لایسنس داخل بکاپ |
| تداخل‌ها | — | — | **تداخل ID** (این ID روی مقصد مال آبجکت دیگری است)، تریگرهایی که تغییر کرده‌اند | — |
| موانع / وابستگی‌ها | PRTG قدیمی‌تر روی مقصد، فضای دیسک، نبودن PRTG و نبودن کلون، نداشتن دسترسی ادمین | نبودن PRTG، دیوایس‌هایی که مقصد ندارد | فرمت جدیدتر تنظیمات، نبودن نوتیفیکیشن‌ها / Scheduleها / Dependencyها | رمز، نبودن PRTG |

دکمهٔ **Restore** فقط بعد از یک پیش‌نمایش بدون مانع فعال می‌شود؛ بازگردانی Full علاوه بر این یک تأیید صریح هم می‌خواهد.

حالت‌های بازگردانی برای بخش‌های تنظیمات:

- حالت **Merge**: فقط چیزهایی که نیستند اضافه می‌شوند؛ به آبجکت‌های موجود هرگز دست زده نمی‌شود (تفاوت‌ها به‌عنوان تداخل فهرست می‌شوند).
- حالت **Overwrite**: آبجکت‌های موجود هم با تنظیمات ذخیره‌شده (داده، تریگرها، کانال‌ها) به‌روز می‌شوند؛ زیرمجموعه‌ها و تاریخچهٔ آن‌ها سر جایشان می‌مانند.
- گزینهٔ **New ids for conflicts** (ID جدید برای تداخل‌ها): آبجکتی که IDاش روی مقصد مال آبجکت دیگری است، با ID جدید ساخته می‌شود (با هر چیزی که زیرش است؛ وابستگی‌های داخل آن هم همراهش درست می‌شوند).

**بازگشت به حالت قبل (Rollback):**

- در **بازگردانی Full**، پوشهٔ دادهٔ مقصد با نام `<data>.pre-restore-<time>` نگه داشته می‌شود و از رجیستری آن Export گرفته می‌شود. اگر بازگردانی شکست بخورد یا PRTG بالا نیاید، هر دو **خودکار سر جایشان برمی‌گردند** و PRTG دوباره روشن می‌شود (گزینهٔ *Roll back automatically* به‌طور پیش‌فرض روشن است). زدن **Cancel** وسط بازگردانی هم همین کار را می‌کند: اگر PRTG متوقف شده باشد، پوشهٔ دادهٔ قبلی، رجیستری و وضعیت فایروال برگردانده می‌شوند (لاگ آن در `<work folder>\rollback\cancelled-restore-<time>.log` نوشته می‌شود، چون خروجی کار لغوشده دور ریخته می‌شود). تا این برگرداندن تمام نشود، سرور برای کارهای دیگر PRTG قفل می‌ماند. اگر خطا پیش از هر تغییری رخ بدهد (مثلاً سرویس‌ها به‌موقع متوقف نشوند یا پوشهٔ داده کنار گذاشته نشود)، PRTG فقط دوباره روشن می‌شود.
- در **بخش‌های تنظیمات**، اول یک کپی از `PRTG Configuration.dat` در `C:\PrtgMover\rollback\config-<time>` گرفته می‌شود؛ تغییر از طریق یک فایل موقت نوشته می‌شود که باید بدون خطا Parse شود؛ اگر PRTG بالا نیاید، همان کپی برگردانده می‌شود. **Cancel** وسط بازگردانی Devices، Notifications یا Triggers هم تنظیمات قبلی را برمی‌گرداند.
- برای **لایسنس**، اول اطلاعات لایسنس فعلی در `C:\PrtgMover\rollback\license-<time>` ذخیره می‌شود.
- در **تاریخچه**، فایل‌هایی که از قبل هستند نگه داشته (Merge) یا جایگزین (Overwrite) می‌شوند؛ هیچ چیزی پاک نمی‌شود؛ کش گراف‌ها کنار گذاشته می‌شود تا PRTG گراف‌ها را از نو حساب کند.

بازگردانی روی خود سرور PRTG (روش *Local*) دیگر دو تا سه برابر حجم بسته روی درایو C: جا نمی‌گیرد: بستهٔ بازشده به‌جای کپی دوباره **سر جایش منتقل (Move) می‌شود** و فایل‌های تاریخچه هم منتقل می‌شوند، نه کپی. فضای خالی پیش از باز کردن بسته بررسی می‌شود، نسخهٔ نیمه‌کارهٔ بازشده پاک می‌شود و بعد از بازگردانی موفق، نسخهٔ بازشده هم حذف می‌شود و دیگر برای همیشه در `data\staging` نمی‌ماند.

سروری با نقش **Source** هرگز مقصد بازگردانی نمی‌شود و به لایسنس و Web Binding آن هم هرگز دست زده نمی‌شود. اگر PRTG Manager را به‌صورت محلی روی یک سرور PRTG نصب کرده‌اید، نقش این کامپیوتر را **Source** بگذارید (*Servers > Edit* یا `install.ps1 -Local -Role source`)؛ نصب‌کننده آن را به‌طور پیش‌فرض با نقش *both* اضافه می‌کند.

روی هر سرور در هر لحظه فقط یک کار اجرا می‌شود که PRTG را متوقف یا تغییر می‌دهد (بازگردانی، مهاجرت، بکاپ، تغییر یا حذف لایسنس، Web Binding)؛ کار دوم رد می‌شود و پیام آن نام کاری را که در حال اجراست می‌گوید.

## <a name="license-page"></a>صفحهٔ لایسنس

| عملیات | چه اتفاقی می‌افتد |
|---|---|
| **Refresh status** | نوع لایسنس (Edition)، نام لایسنس، تعداد سنسورها، وضعیت فعال‌سازی، آخرین پیام فعال‌سازی PRTG، اینکه کدام مقادیر لایسنس وجود دارند (بدون نمایش خود مقادیر) و اثر انگشت (Fingerprint) شناسهٔ سیستم. |
| **Add free trial license** | نام و کلید Trial را وارد کنید؛ همان که Paessler بعد از ثبت‌نام در [paessler.com/prtg/download](https://www.paessler.com/prtg/download) برایتان ایمیل می‌کند. |
| **Activate an authorized license** | نام و کلید لایسنسی را که دارید (Site، Enterprise و…) همان‌طور که در [فروشگاه Paessler](https://shop.paessler.com) نوشته شده وارد کنید. |
| **Back up license** | بکاپ رمزگذاری‌شدهٔ لایسنس (توضیحش بالاتر آمد). |
| **Restore license from backup** | از طریق پنجرهٔ بازگردانی، با پیش‌نمایش. |
| **Remove license** | نام لایسنس، کلید و فعال‌سازی همان کلید (و فایل‌های لایسنس) را حذف می‌کند؛ اطلاعات داخلی خود PRTG (تاریخ نصب، شمارندهٔ سنسورهای Pauseشده) دست نمی‌خورد. برای تأیید باید نام سرور را تایپ کنید. یک کپی روی خود سرور نگه داشته می‌شود. |

نصب کلید درست مثل *PRTG Administration Tool* انجام می‌شود: PRTG متوقف می‌شود، نام و کلید نوشته می‌شوند، PRTG دوباره روشن می‌شود و **خود PRTG کلید را آنلاین با Paessler فعال می‌کند**. بعد PRTG Manager فقط خطوطی از لاگ را می‌خواند که بعد از همین روشن شدن نوشته شده‌اند و نتیجه را توضیح می‌دهد؛ مثلاً *HTTP 403: the key is active on another system — move the activation in the Paessler shop*، یعنی کلید روی سیستم دیگری فعال است و باید فعال‌سازی را در فروشگاه Paessler منتقل کنید.

کارهایی که PRTG Manager عمداً **انجام نمی‌دهد**: ساختن، دریافت یا تغییر کلید لایسنس، ریست کردن Trial، دور زدن یا جعل فعال‌سازی. Paessler هیچ رابط عمومی‌ای ندارد که کلید تحویل بدهد؛ پس «دریافت از اینترنت» یعنی شما کلید را از فروشگاه یا ایمیل Paessler برمی‌دارید و PRTG Manager آن را فعال می‌کند. فعال‌سازی آفلاین همچنان در رابط وب PRTG انجام می‌شود (*Setup › License Status*).

## <a name="connection-methods"></a>روش‌های اتصال

هر سرور یک روش اتصال دارد (*Servers → Edit*):

| | **Local** | **RDP (agent)** | **WinRM** |
|---|---|---|---|
| محل اجرای PRTG Manager | روی خود سرور PRTG | روی یک کامپیوتر Manager | روی یک کامپیوتر Manager |
| نیازمندی روی سرور | هیچ (اجرا با دسترسی Administrator) | دسترسی Remote Desktop | PowerShell Remoting (`tools\Enable-PrtgManagerRemoting.ps1`) |
| هنگام اجرای یک کار | — | پنجرهٔ Remote Desktop باید باز بماند | هیچ |

همهٔ روش‌ها همان Payload را اجرا می‌کنند (`src\Remote\PrtgManager.Remote.ps1`). برای تغییر لایسنس یا بازگردانی یک بخش از تنظیمات، روش *Local* یا *WinRM* لازم است. در مهاجرت، گزینهٔ *How the files move* (نحوهٔ انتقال فایل‌ها) می‌تواند WireGuard یا IPIP هم باشد، یعنی یک تونل بین دو سرور.

## <a name="installation"></a>نصب

روی **`install.cmd`** دوبار کلیک کنید، یا:

<div dir="ltr">

```powershell
git clone https://github.com/Digitalvps-Ir/prtg-mover.git
cd prtg-mover
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

</div>

نصب‌کننده برنامه را در `C:\PrtgManager` کپی می‌کند (نصب قبلی PRTG Mover در `C:\PrtgMover` همان‌جا به‌روز می‌شود)، همهٔ اسکریپت‌ها و داشبورد را تست می‌کند، میان‌بر **PRTG Manager** را می‌سازد و داشبورد را روی `http://localhost:8765/` اجرا می‌کند.

| گزینه | معنی |
|---|---|
| `-InstallPath <folder>` | نصب در یک پوشهٔ دیگر. |
| `-Source <folder or zip>` | نصب از این پوشه یا فایل zip، به‌جای پوشهٔ خود نصب‌کننده. |
| `-Local` | نصب PRTG Manager روی خود سرور PRTG (با دسترسی Administrator): این کامپیوتر با روش اتصال *Local* اضافه می‌شود و داشبورد با روشن شدن کامپیوتر بالا می‌آید. یک Watchdog (تریگر دوم تسک *PRTG Manager Dashboard* که هر ۵ دقیقه اجرا می‌شود) داشبوردی را که متوقف شده حداکثر ظرف ۵ دقیقه دوباره اجرا می‌کند، نه در ری‌استارت بعدی؛ به داشبوردی که در حال اجراست کاری ندارد. |
| `-Role both\|source\|target` | همراه با `-Local`: نقش این کامپیوتر در فهرست سرورها (پیش‌فرض *both*). سروری با نقش *source* هرگز مقصد بازگردانی نمی‌شود. |
| `-Autostart` / `-NoAutostart` | اجرای خودکار با ویندوز را روشن / خاموش می‌کند. |
| `-TrustedHosts a,b` | WinRM ساده (HTTP) را برای این سرورها آماده می‌کند. |
| `-Port`، `-NoShortcut`، `-NoStart`، `-Uninstall` | پورت داشبورد، نساختن میان‌بر، اجرا نکردن داشبورد بعد از نصب، حذف برنامه. |

اطلاعات شما (`config\`، `data\`، `backups\`، `installers\`) با به‌روزرسانی یا حذف برنامه هرگز دست نمی‌خورد.

**نصب هر دو برنامه با یک فایل (PRTG Manager و VPN Manager):** دستور `tools\Build-SetupAll.ps1 -VpnManagerSource <VPN Manager folder>` فایل `Setup-All.cmd` را می‌سازد. روی یک کامپیوتر ویندوزی رویش دوبار کلیک کنید: هر دو برنامه را نصب یا به‌روز می‌کند (PRTG Manager در `C:\PrtgManager` و VPN Manager در `C:\VpnManager`؛ نصب‌های قدیمی‌تر همان‌جا به‌روز می‌شوند)، میان‌برها را می‌سازد، هر دو را همراه ویندوز اجرا می‌کند و هر دو داشبورد را تست می‌کند. گزینه‌ها: `-SkipPrtgManager`، `-SkipVpnManager`، `-PrtgManagerPath`، `-VpnManagerPath`، `-NoAutostart` (نام‌های قدیمی مثل `-PrtgMoverPath` هم هنوز کار می‌کنند).

## <a name="quick-start-migrate-a-prtg-server"></a>شروع سریع: انتقال یک سرور PRTG

1. در **Servers → Add server** سرور قدیمی PRTG (نقش *Source*) و سرور جدید (نقش *Target*) را اضافه کنید.
2. دکمهٔ **Test all** را بزنید — همهٔ سرورها باید `PASS` نشان بدهند.
3. در **Backup & Migrate** نوع *Full* را انتخاب کنید، مقصد(ها) را تیک بزنید و **Migrate** را بزنید. کادر *What this job will do* دقیقاً می‌گوید چه چیزهایی کپی می‌شود.
4. لاگ زنده را در صفحهٔ **Jobs** دنبال کنید. کار هر مقصد با `PRTG ok` و آدرس وب آن تمام می‌شود — یا با `rolled back` و دلیلش.
5. در صفحهٔ **License** سرور مقصد، PRTG از Paessler فعال‌سازی تازه‌ای برای همان سرور می‌خواهد.

## <a name="dashboard"></a>داشبورد

| صفحه | کاربرد |
|---|---|
| **Overview** | شمارنده‌ها و کارهای اخیر. |
| **Servers** | فهرست سرورها، روش اتصال، پورت‌ها، تست‌ها، نسخهٔ PRTG، نشان (Badge) لایسنس. |
| **Backup & Migrate** | نوع بکاپ، گزینه‌ها، رمز بکاپ، مقصدهای مهاجرت و خلاصه‌ای به زبان ساده. |
| **Backups** | نام، نوع، مبدأ، زمان ساخت، حجم، فرمت و نسخهٔ PRTG، رمزگذاری‌شده یا نه، معتبر یا نه — با دکمه‌های **Download**، **Validate**، **Inspect**، **Restore** و **Delete**. دکمهٔ Delete فایل را به Recycle Bin می‌برد؛ اما وقتی داشبورد با حساب SYSTEM اجرا می‌شود (همان تسکی که با روشن شدن سیستم اجرا می‌شود)، فایل برای همیشه حذف می‌شود و این را پیش از تأیید به شما می‌گوید، چون Recycle Bin حساب SYSTEM دیده نمی‌شود و فضایی هم آزاد نمی‌کند (حالت حذف در `/api/info` با `deleteMode` گزارش می‌شود). آپلود فایل‌های `.zip` و `.pmenc`. کارت **Leftovers on this computer** (باقی‌مانده‌ها روی این کامپیوتر): بسته‌های بازشده، مراحل موقت بازگردانی، کپی‌های Rollback، پوشه‌های دادهٔ قبلی PRTG (`.pre-restore-*`، `.failed-restore-*`) و Snapshotهای VSS اجراهای نیمه‌کاره، همراه با حجم هرکدام و دکمهٔ Remove. فقط موارد همین فهرست، بعد از تأیید و فقط وقتی هیچ کاری در حال اجرا نیست حذف می‌شوند (`GET /api/leftovers`، `POST /api/leftovers/remove`). |
| **License** | وضعیت، کلید Trial / Authorized، بکاپ، بازگردانی، حذف لایسنس. |
| **Jobs** | پیشرفت کار، لاگ زنده، نتیجهٔ هر مقصد، Resume / Retry، Cancel، دانلود لاگ. |
| **Logs & Audit** | سابقهٔ Audit (بکاپ‌ها، بازگردانی‌ها، Validateها، تغییرات لایسنس، حذف‌ها) و لاگ Manager. |

پیام‌های خطا می‌گویند چه چیزی، کجا و چرا شکست خورد و چه باید کرد؛ مثلاً *Delete backup failed on PRTG-FULL_X.zip: the file could not be moved to the Recycle Bin (…) — Nothing was deleted.*

داشبورد خودش را جمع‌وجور نگه می‌دارد (Housekeeping): کارهای تمام‌شده بعد از یک ساعت از حافظه بیرون می‌روند (سوابقشان روی دیسک می‌ماند) و فهرست کارها دیگر هر چند ثانیه همهٔ فایل‌های کار را از نو نمی‌خواند. روزی یک بار لاگ‌های Manager و robocopy قدیمی‌تر از ۳۰ روز و سوابق کارهای قدیمی‌تر از ۹۰ روز پاک می‌شوند (۲۰۰ مورد جدیدتر همیشه می‌مانند) و لاگ Audit در ۱۰ مگابایت چرخانده (Rotate) می‌شود. خطا هنگام دریافت یک درخواست هم داشبورد را از کار نمی‌اندازد؛ فقط در لاگ ثبت می‌شود و داشبورد به کارش ادامه می‌دهد.

## <a name="command-line"></a>خط فرمان

<div dir="ltr">

```powershell
.\cli\Invoke-PrtgManager.ps1 -Action Test -Source 10.0.0.10 -Credential (Get-Credential)
.\cli\Invoke-PrtgManager.ps1 -Action Backup -Source PRTG-OLD -KeepLast 7
.\cli\Invoke-PrtgManager.ps1 -Action Backup -Source PRTG-OLD -Scope Graphs -HistoryDays 30
.\cli\Invoke-PrtgManager.ps1 -Action BackupPart -Part Devices -Source PRTG-OLD
.\cli\Invoke-PrtgManager.ps1 -Action BackupPart -Part License -Source PRTG-OLD -BackupPassword (Read-Host -AsSecureString)
.\cli\Invoke-PrtgManager.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW1,PRTG-NEW2 -Streams 6
.\cli\Invoke-PrtgManager.ps1 -Action Restore -BackupName PRTG-FULL_OLDSRV_20260928-221500.zip -Target PRTG-NEW1
.\cli\Invoke-PrtgManager.ps1 -Action FixBinding -Target PRTG-NEW1
.\cli\Invoke-PrtgManager.ps1 -Action RemoveLicense -Target PRTG-NEW1
```

</div>

کدهای خروج (Exit code): `0` موفق، `1` ناموفق، `2` کار تمام شد ولی روی یکی از مقصدها خطا داشت.

## <a name="backup-package-format-version-2"></a>ساختار بستهٔ بکاپ (نسخهٔ 2)

هر بسته به شکل `backups\PRTG-<TYPE>_<SOURCE>_<yyyyMMdd-HHmmss>.zip` ذخیره می‌شود — یا اگر با رمز بکاپ رمزگذاری شده باشد با پسوند `.pmenc` — و کنارش فایل `<package>.meta.json` قرار می‌گیرد (SHA-256 فایل، Manifest و نتیجهٔ آخرین Validate).

فایل `manifest.json`:

| فیلد | معنی |
|---|---|
| `tool`، `format`، `formatVersion` | `prtg-manager`، `prtg-manager-backup`، `2` (بسته‌های PRTG Mover: `prtg-mover`، `1` — همچنان قابل بازگردانی) |
| `type` | `full`، `graphs`، `devices`، `notifications`، `triggers`، `license` |
| `appVersion`، `createdUtc`، `jobId` | کدام نسخهٔ PRTG Manager و چه زمانی آن را ساخته است |
| `source` | کامپیوتر، سیستم‌عامل، نام سرور در فهرست سرورها |
| `components` | نسخهٔ PRTG، نسخهٔ Manager، نسخهٔ PowerShell |
| `sections`، `counts` | چه چیزهایی داخل بسته است (مثلاً `device=27, sensor=386`) |
| `files` | مسیر، حجم و SHA-256 هر فایل در بسته‌های بخشی |
| `prtg` | نسخه، فرمت تنظیمات، SHA-256 و آمار تنظیمات، مسیرها، پوشه‌های برنامه، سرویس‌ها |
| `graphs` | تعداد روزها، اولین و آخرین روز، فایل‌ها، حجم، دیوایس‌ها (در بسته‌های History) |
| `license` | نام مقادیر، Edition، فعال بودن یا نبودن (هرگز خود کلید) |
| `encryption` | `package` (کل فایل) / `secrets` (کلید لایسنس)، الگوریتم، روش ساخت کلید |

بسته‌های بخشی شامل `devices.xml`، `notifications.xml`، `triggers.xml` (یک `<prtgmanagersection>` همراه با فرمت تنظیمات و نسخهٔ PRTG) یا `license.enc` هستند. بسته‌های Full و History شامل `prtg\data`، `prtg\graphs`، `prtg\programfull`، `prtg\program`، `prtg\registry`، `prtg\services`، `desktop` و `extra` هستند.

دکمهٔ **Validate** این‌ها را بررسی می‌کند: فایل در برابر SHA-256 اصلی‌اش، سالم بودن zip، پشتیبانی از فرمت، چک‌سام تک‌تک فایل‌های فهرست‌شده، `PRTG Configuration.dat` در برابر چک‌سامی که روی مبدأ خوانده شده، تعداد فایل‌های تاریخچه، و در بسته‌های رمزگذاری‌شده، رمز و سلامت فایل (HMAC).

## <a name="security"></a>امنیت

- رمز سرورها با DPAPI ویندوز و فقط برای کاربر فعلی ویندوز ذخیره می‌شود؛ فایل `config\servers.json` هیچ رمزی در خود ندارد.
- رمزهای بکاپ و کلیدهای لایسنس فقط در همان کار در حال اجرا به کار می‌روند: هرگز در سوابق کارها، لاگ‌ها، Audit یا URLها نوشته نمی‌شوند.
- بکاپ لایسنس روی خود سرور PRTG رمزگذاری می‌شود و رمزگشایی هنگام بازگردانی روی سرور مقصد انجام می‌شود. Manager هرگز کلید را به‌صورت متن ساده در اختیار ندارد.
- داشبورد روی `localhost` و بدون هیچ محافظت دسترسی (بدون Token) گوش می‌دهد. هر برنامه‌ای روی Manager می‌تواند از آن استفاده کند و با `-ListenAll` هر کسی که به پورت برسد. فقط وقتی لازمش دارید اجرایش کنید.
- بکاپ‌های Full شامل تنظیمات PRTG همراه با اطلاعات ورود رمزگذاری‌شدهٔ دیوایس‌ها، لایسنس و کلید خصوصی SSL هستند: از رمز بکاپ استفاده کنید یا آن‌ها را مثل خروجی یک Password Vault نگه دارید.
- پوشه‌های `backups/` و `data/` و فایل `config/servers.json` در `.gitignore` هستند — هرگز آن‌ها را Commit نکنید.

## <a name="limitations-and-after-migration-checklist"></a>محدودیت‌ها و چک‌لیست بعد از انتقال

- **دو Core هم‌زمان**: با گزینهٔ *Don't touch the source* (دست نزدن به مبدأ)، PRTG قدیمی تا وقتی خودتان متوقفش نکنید روشن می‌ماند.
- **فعال‌سازی لایسنس** به سیستم وابسته است: روی سرور جدید، PRTG تا وقتی Paessler لایسنس را همان‌جا فعال نکند، وضعیت *No License (System Changed)* را نشان می‌دهد. به لایسنس مبدأ هرگز دست زده نمی‌شود.
- **تداخل ID**: بازگردانی دیوایس‌ها در یک PRTG که جداگانه راه‌اندازی شده ممکن است روی ID آبجکت‌ها تداخل پیدا کند؛ از *New ids for conflicts* استفاده کنید (در این صورت تاریخچه دنبال آن آبجکت‌ها نمی‌آید).
- **بازگردانی تاریخچه** فقط برای دیوایس‌هایی دیده می‌شود که همان IDهای مبدأ را دارند (خود مبدأ، یا سروری که از بکاپ Full همان مبدأ بازگردانی شده است).
- **نکته‌های همیشگی** هم مثل قبل برقرارند: دیوایس‌هایی که فقط IP قدیمی را قبول می‌کنند، Remote Probeها (آدرس Core)، حساب سرویس (کلون‌ها با LocalSystem اجرا می‌شوند) و نسخهٔ مقصد (باید برابر یا جدیدتر باشد).
- **ساعت Manager**: تا وقتی ساعت Manager عقب باشد، گواهی HTTPS مربوط به WinRM نامعتبر به نظر می‌رسد؛ ابزار صبر می‌کند تا گواهی معتبر شود.

## <a name="coming-from-prtg-mover"></a>آمدن از PRTG Mover

- نصب‌کننده و `Setup-All.cmd` نصب موجود در `C:\PrtgMover` را همان‌جا به‌روز می‌کنند؛ سرورها، اطلاعات ورود و بکاپ‌ها سر جایشان می‌مانند. میان‌برها و تسک اجرای خودکار با ویندوز به **PRTG Manager** تغییر نام می‌دهند؛ فایل‌های `Start-PrtgMover.ps1`، `Start-PrtgMover.cmd`، `Open-PrtgMover.ps1`، `tools\Enable-PrtgMoverRemoting.ps1` و `cli\Invoke-PrtgMover.ps1` به‌شکل فایل‌های کوچکی می‌مانند که کار را به نسخهٔ جدید می‌سپارند (Forwarder)، تا میان‌برها و تسک‌های قدیمی همچنان کار کنند.
- بسته‌های PRTG Mover (فرمت 1) با نوع *Full* نمایش داده می‌شوند و مثل قبل بازگردانی می‌شوند. بخش VPN آن‌ها اینجا نادیده گرفته می‌شود — بسته را در **VPN Manager** وارد (Import) کنید. بسته‌هایی که فقط VPN دارند (`VPN_*.zip`) دیگر در PRTG Manager نمایش داده نمی‌شوند.
- این نام‌ها به‌عنوان شناسهٔ فنی باقی مانده‌اند: پوشهٔ کاری روی سرورها `C:\PrtgMover` (کپی‌های Rollback آنجا هستند)، پیشوند لینک VSS یعنی `PrtgMoverVss_`، متغیرهای محیطی `PRTGMOVER_*` و نام مخزن GitHub یعنی `prtg-mover`.

## <a name="project-layout"></a>ساختار پروژه

<div dir="ltr">

```
install.ps1 / .cmd                  installs, updates or removes PRTG Manager
Start-PrtgManager.ps1 / .cmd        dashboard (HttpListener) + REST API
Open-PrtgManager.ps1                opens the running dashboard (or starts it)
cli\Invoke-PrtgManager.ps1          command-line front end
src\PrtgManager.psm1                manager engine: inventory, sessions, transfers, packages, jobs
src\Remote\PrtgManager.Remote.ps1   code executed on the servers (backup, restore, parts, license, encryption)
agent\PrtgManager-Agent.ps1         agent for the RDP connection method
web\                                dashboard UI (vanilla HTML/CSS/JS)
tools\Enable-PrtgManagerRemoting.ps1  WinRM method: run once on every server
tools\Build-SetupAll.ps1            builds Setup-All.cmd (PRTG Manager + VPN Manager in one file)
tests\                              Pester tests
```

</div>

## <a name="development"></a>توسعه

<div dir="ltr">

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

</div>

مجموعهٔ تست‌ها مسیر بکاپ، انتقال و بازگردانی را بدون هیچ سروری اجرا می‌کند (روش اتصال *Local* و یک RDP Agent محلی)، و علاوه بر آن برنامه‌ریز و ادغام‌کنندهٔ بخش‌های تنظیمات را روی یک نمونه تنظیمات PRTG، رمزگذاری، Validate بسته‌ها، مدیریت لایسنس روی یک کلید رجیستری موقت و API داشبورد را تست می‌کند. CI (GitHub Actions روی `windows-latest` با Windows PowerShell 5.1) همهٔ اسکریپت‌ها را Parse می‌کند و PSScriptAnalyzer و تست‌های Pester را اجرا می‌کند.

## <a name="license"></a>مجوز انتشار

این پروژه با مجوز [MIT](LICENSE) منتشر شده است.

</div>
