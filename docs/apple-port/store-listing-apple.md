# App Store listing — EN / AR

Ported from the Android `docs/store-listing.md`, but **not** a translation of it. Four claims in the Play
listing are false on Apple and are gone rather than softened:

| Play listing says | Apple reality |
|---|---|
| "One-time model download (internet required)" | Models are **bundled**. The app has no networking code at all. This is a selling point on Apple, not a caveat. |
| "Supports MP4, MKV, and WebM" | AVFoundation cannot demux Matroska. **MP4 · MOV · M4V.** Claiming MKV would generate one-star reviews from people whose file won't open. |
| "Optimized for ARM64 devices (Android 8.0+)" | iOS 18 / macOS 15, Apple silicon. |
| "Background processing" | iOS suspends the app. The honest promise is **resume**, not background work — see the copy below, which says so on the storefront rather than only in-app. |

Apple's fields are shorter than Play's, so the long description is rebuilt rather than trimmed.

---

## 🇬🇧 English

**App Name** (30 max) — `Naqi — Halal Video Filter` (25)

**Subtitle** (30 max) — `Private on-device filtering` (27)

**Promotional Text** (170 max, editable without review)
> Remove music and censor faces without a single byte leaving your iPhone. No account, no upload, no
> internet — and your original file is never touched.

**Keywords** (100 max, comma-separated, no spaces after commas — spaces waste characters)
```
halal,islamic,muslim,video,filter,censor,blur,music,remove,modest,offline,private,ondevice,editor
```
(97 chars. Do not repeat the app name or subtitle words — Apple already indexes those.)

**Description** (4000 max)

> **Filter videos on your device. Nothing is uploaded, ever.**
>
> Naqi removes music from a video and censors the faces you choose, running every model directly on
> your iPhone, iPad or Mac. There is no account, no server and no network request — the app ships with
> everything it needs and works in Airplane Mode from the moment you install it.
>
> **Remove music, keep speech**
> An on-device separation model pulls the soundtrack out and leaves dialogue behind, so lectures,
> documentaries and shows stay watchable.
>
> **Censor faces and flagged scenes**
> Choose whose faces to cover — women or men — and Naqi tracks them through the video and blurs them.
> Whole scenes it flags as inappropriate are covered entirely. A strictness control sets how cautious
> that judgement is.
>
> **Your original is never changed**
> Naqi only ever reads the file you picked. The filtered version is saved as a new video; the original
> stays exactly where it was, byte for byte.
>
> **Genuinely private**
> No data collection. No analytics. No third-party SDKs. No account. The app contains no networking
> code, so there is nothing to trust us about — put the device in Airplane Mode and it works the same.
>
> **Built for long videos**
> A feature-length film takes a while, and iOS will suspend an app you switch away from. Naqi
> checkpoints as it goes: leave, come back, and it picks up where it stopped instead of starting over.
>
> **Works with**
> MP4, MOV and M4V. iPhone, iPad and Mac.
>
> **What it is not**
> Naqi uses machine learning and machine learning is not perfect. A face that is never shown clearly
> can be missed. High strictness deliberately over-censors — it is built to err toward covering too
> much rather than too little. Long videos take minutes, not seconds. Naqi is a tool for filtering
> your own media for yourself and your family.
>
> **Naqi** means *pure* in Arabic.

**Category** — Primary: Photo & Video · Secondary: Utilities
(Play used "Video Players & Editors"; Apple's nearest equivalent is Photo & Video. "Lifestyle" is a
worse secondary than Utilities here — the app is a tool, and Utilities is a less crowded chart.)

**Age rating** — 4+. Naqi displays no content of its own; it processes the user's files.

---

## 🇸🇦 العربية

**اسم التطبيق** — `نقي — فلتر الفيديو الحلال`

**العنوان الفرعي** — `فلترة خاصة على جهازك`

**النص الترويجي**
> أزل الموسيقى وغطِّ الوجوه دون أن تغادر بايت واحدة جهازك. بلا حساب، بلا رفع، وبلا إنترنت — وملفك
> الأصلي لا يُمَس أبداً.

**الكلمات المفتاحية**
```
حلال,إسلامي,مسلم,فيديو,فلتر,رقابة,طمس,موسيقى,إزالة,محتشم,محلي,خصوصية,محرر
```

**الوصف**

> **فلتر فيديوهاتك على جهازك. لا شيء يُرفع، أبداً.**
>
> يزيل نقي الموسيقى من الفيديو ويغطي الوجوه التي تختارها، وتعمل كل النماذج مباشرةً على جهازك — آيفون
> أو آيباد أو ماك. لا حساب، لا خادم، ولا أي طلب شبكة؛ يأتي التطبيق بكل ما يحتاجه ويعمل في وضع الطيران
> منذ لحظة التثبيت.
>
> **أزل الموسيقى واحتفظ بالكلام**
> نموذج فصل محلي يسحب الموسيقى ويترك الحوار، فتبقى المحاضرات والوثائقيات والبرامج قابلة للمشاهدة.
>
> **غطِّ الوجوه والمشاهد المُعلَّمة**
> اختر وجوه مَن تريد تغطيتها — النساء أو الرجال — فيتتبعها نقي عبر الفيديو ويطمسها. أما المشاهد التي
> يُصنّفها غير لائقة فتُغطى بالكامل. ويحدد مستوى الصرامة مدى تحفّظ هذا الحكم.
>
> **ملفك الأصلي لا يتغير**
> لا يقرأ نقي سوى الملف الذي اخترته. تُحفظ النسخة المُفلترة كفيديو جديد، ويبقى الأصل كما هو تماماً،
> بايت ببايت.
>
> **خصوصية حقيقية**
> لا جمع بيانات. لا تحليلات. لا مكتبات طرف ثالث. لا حساب. لا يحتوي التطبيق على أي كود شبكة، فلا شيء
> عليك أن تصدّقنا فيه — ضع الجهاز في وضع الطيران وسيعمل كما هو.
>
> **مبني للفيديوهات الطويلة**
> الفيلم الكامل يستغرق وقتاً، وiOS يوقف التطبيق الذي تنتقل منه. لذلك يحفظ نقي تقدّمه أولاً بأول:
> اخرج ثم عُد، فيكمل من حيث توقف بدل أن يبدأ من جديد.
>
> **الصيغ المدعومة**
> MP4 و MOV و M4V. آيفون وآيباد وماك.
>
> **ما ليس عليه**
> يستخدم نقي تعلّم الآلة، وتعلّم الآلة ليس مثالياً. قد يُفوَّت وجه لا يظهر بوضوح قط. والصرامة العالية
> تُبالغ في التغطية عن قصد — فهي مبنية لتخطئ في اتجاه التغطية الزائدة لا الناقصة. والفيديوهات الطويلة
> تستغرق دقائق لا ثوانٍ. نقي أداة لفلترة وسائطك أنت، لك ولأسرتك.
>
> **نقي** تعني *طاهر* بالعربية.

---

## App Review notes (submit with the build)

> Naqi processes video entirely on the device. It contains no networking code and makes no network
> requests; all four ML models are bundled in the app. There is no account, no analytics and no
> third-party SDK. Reviewing offline (Airplane Mode) exercises the full feature set.
>
> To test: tap **Pick a video**, choose any video from the library, enable either operation, and tap
> Continue. A 10–15 second clip finishes in well under a minute. The filtered result is saved as a new
> item in Photos; the source video is opened read-only and is not modified.
>
> The face-censoring feature covers the faces of a gender the user selects (the picker offers Women or
> Men). It is a modesty filter applied by a user to their own media, for personal and family viewing —
> analogous to a parental content filter. It makes no judgement about people and displays no content of
> its own.

**Flagged for the submitter, not for Apple:** the Play listing's "Censor Women in Videos" headline does
not survive contact with App Review as a *storefront* claim as cleanly as the neutral framing above,
which is also more accurate — the shipped picker is Women | Men. The copy in this document is written
that way deliberately. Do not paste the Android headline back in.

## Screenshots

Six per device class (6.9" iPhone, 13" iPad, Mac), EN and AR, RTL laid out for AR. The in-app captures
are already generated at `docs/apple-port/screenshots/`; they need caption plates added.

| # | Screen | EN caption | AR caption |
|---|---|---|---|
| 1 | Pick | Nothing leaves your device | لا شيء يغادر جهازك |
| 2 | Options | Choose exactly what to filter | اختر بالضبط ما تريد فلترته |
| 3 | Options / strictness | You set how cautious it is | أنت تحدد مدى التحفّظ |
| 4 | Progress | Leave and come back — it resumes | اخرج وعُد — يكمل من حيث توقف |
| 5 | Done | Your original is untouched | ملفك الأصلي كما هو |
| 6 | About | No account. No network. No analytics. | بلا حساب. بلا شبكة. بلا تتبّع. |

## Privacy nutrition label

**Data Not Collected** — every category. `naqi/PrivacyInfo.xcprivacy` declares `NSPrivacyTracking=false`,
no collected data types, and three required-reason APIs (file timestamp `C617.1`, disk space `E174.1`,
user defaults `1C8F.5`), each traced to its call site in the manifest's comments.
