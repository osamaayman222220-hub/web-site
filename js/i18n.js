// ============================================================
// رعايه - Translations (i18n)
// Bilingual: Arabic (RTL) + English (LTR)
// ============================================================

const TRANSLATIONS = {
  ar: {
    // Top Emergency Banner
    emergency_label: 'تنبيه طبي عاجل',
    emergency_notice: 'منصة رعايه مخصصة للرعاية التمريضية والزيارات المنزلية المجدولة، ولا تحل محل خدمات الطوارئ أو الحالات الحرجة. في حالات الطوارئ الطبية العاجلة، يُرجى الاتصال فوراً بالإسعاف المصري.',
    emergency_call: 'إسعاف مصر 123',

    // Navigation
    nav_home: 'الرئيسية',
    nav_nurses: 'الممرضون',
    nav_how_it_works: 'كيف يعمل',
    nav_faq: 'الأسئلة الشائعة',
    nav_contact: 'تواصل معنا',
    nav_login: 'تسجيل الدخول',
    nav_register: 'إنشاء حساب',
    nav_dashboard: 'لوحة التحكم',
    nav_profile: 'الملف الشخصي',
    nav_logout: 'تسجيل الخروج',

    // Hero
    hero_badge: 'منصة التمريض المنزلي والرعاية الصحية في مصر',
    hero_title: 'رعاية تمريضية',
    hero_title_2: 'احترافية في منزلك',
    hero_subtitle: 'نربطك بأفضل الكوادر التمريضية المؤهلة لتلقي الرعاية الصحية في راحة وأمان منزلك',
    hero_book_nurse: 'احجز ممرضاً',
    hero_find_nurse: 'ابحث عن ممرض',
    stat_nurses: 'كوادر تمريضية',
    stat_governorates: 'محافظة بمصر',
    stat_home_care: 'رعاية منزلية',

    // Services
    services_title: 'خدماتنا التمريضية',
    services_subtitle: 'نقدم طيفاً واسعاً من الخدمات التمريضية المنزلية المتخصصة بأيدي كوادر مؤهلة',
    service_wound: 'رعاية الجروح',
    service_wound_desc: 'تغيير الضمادات ورعاية الجروح والقرح السريرية بأيدٍ متخصصة ومعقمة',
    service_injection: 'الحقن والأدوية',
    service_injection_desc: 'إعطاء الحقن العضلية والوريدية وتركيب المحاليل بدقة وأمان تام',
    service_elderly: 'رعاية كبار السن',
    service_elderly_desc: 'رعاية يومية ومتابعة صحية شاملة لأحبائنا من كبار السن في منازلهم',
    service_postop: 'ما بعد العمليات',
    service_postop_desc: 'متابعة التعافي وقياس المؤشرات الحيوية بعد العمليات الجراحية',
    service_baby: 'رعاية الأطفال',
    service_baby_desc: 'رعاية متخصصة لحديثي الولادة والأطفال مع دعم وإرشاد للأمهات',
    service_physiotherapy: 'العلاج الطبيعي',
    service_physiotherapy_desc: 'جلسات علاج طبيعي وتأهيل حركي منزلي تحت إشراف متخصصين',

    // How it works
    how_title: 'كيف تعمل منصة رعايه؟',
    how_step1_title: 'سجّل حسابك',
    how_step1_desc: 'أنشئ حسابك بسهولة كمريض لتطلب الخدمة أو كممرض لتقدم خدماتك',
    how_step2_title: 'اختر الممرض',
    how_step2_desc: 'تصفح الكوادر التمريضية حسب المحافظة والتخصص والتقييمات الحقيقية',
    how_step3_title: 'حدد الموعد والعنوان',
    how_step3_desc: 'اختر الخدمة والوقت المناسب وأرسل طلب الزيارة المنزلية مباشرة',
    how_step4_title: 'استقبل الرعاية',
    how_step4_desc: 'يصلك الممرض المؤهل في موعده لتقديم الرعاية الطبية المطلوبة بكل راحة',

    // Featured Nurses
    nurses_title: 'الممرضون المتاحون',
    nurses_subtitle: 'تصفح الكوادر التمريضية المسجلة في مصر',
    view_all_nurses: 'عرض جميع الممرضين ←',

    // Nurses Directory Page
    nurses_header_title: 'اعثر على الممرض المناسب لرعايتك المنزلية',
    nurses_header_subtitle: 'تصفح الكوادر التمريضية المتاحة للزيارات المنزلية والرعاية التمريضية المتخصصة في محافظتك',
    filter_search_label: 'بحث سريع',
    filter_search_placeholder: '🔍 ابحث باسم الممرض أو التخصص أو المدينة...',
    filter_gov_label: 'المحافظة',
    filter_gov_all: 'جميع محافظات مصر',
    filter_city_label: 'المدينة / المنطقة',
    filter_city_placeholder: 'اختر المحافظة أولاً',
    filter_specialty_label: 'التخصص',
    filter_specialty_all: 'جميع التخصصات',
    filter_price_label: 'الحد الأقصى لسعر الزيارة',
    filter_price_any: 'أي سعر',
    filter_reset_btn: 'إعادة ضبط الفلاتر',
    nurses_available_title: 'الممرضون المتاحون',
    nurses_count_suffix: 'ممرض متاح',
    nurse_exp_label: 'الخبرة',
    nurse_exp_years: 'سنوات',
    nurse_price_label: 'سعر الزيارة',
    nurse_price_per_visit: 'ج.م / زيارة',
    not_specified: 'لم يحدد بعد',
    status_verified: '✓ معتمد وموثق',
    status_pending: '⏳ قيد المراجعة',
    status_unavailable: 'حالة التوثيق غير متاحة',
    btn_view_profile: 'عرض الملف الشخصي',
    btn_book_visit: '📅 احجز زيارة',
    nurse_modal_title: 'الملف المهني للممرض',
    nurse_modal_bio: 'نبذة تعريفية',
    nurse_modal_qualifications: 'المؤهلات والاعتمادات',
    nurse_modal_location: 'منطقة الخدمة',
    nurse_modal_close: 'إغلاق',
    empty_no_nurses: 'لا يوجد ممرضون متاحون حالياً في قاعدة البيانات',
    empty_no_matches: 'لا يوجد ممرضون مطابقون لمعايير البحث المحددة',
    empty_no_matches_desc: 'جرّب تغيير خيارات البحث أو تصفية المحافظة أو إعادة ضبط الفلاتر.',
    error_fetch_nurses: 'تعذّر تحميل بيانات الممرضين من قاعدة البيانات',
    btn_retry: 'إعادة المحاولة 🔄',

    // Reviews
    reviews_title: 'تقييمات وتجارب المرضى',
    reviews_subtitle: 'آراء وتقييمات واقعية من مستخدمي خدمات الرعاية المنزلية بعد إتمام الزيارات',

    // FAQ
    faq_title: 'الأسئلة الشائعة',
    faq1_q: 'كيف أسجل حساباً في منصة رعايه؟',
    faq1_a: 'اضغط على "إنشاء حساب" في أعلى الصفحة، واختر نوع الحساب (مريض أو ممرض)، ثم أدخل بياناتك الأساسية ورقم هاتفك المصري لتأكيد حسابك والبدء في استخدام المنصة.',
    faq2_q: 'كيف يتم حجز زيارة تمريضية؟',
    faq2_a: 'بعد تسجيل الدخول، تصفح قائمة الممرضين واختر الأنسب لمحافظتك وتخصصك، ثم اضغط "احجز زيارة" وحدد التاريخ والوقت والعنوان المطلوب لتأكيد موعد الزيارة.',
    faq3_q: 'هل تغطي المنصة جميع المحافظات؟',
    faq3_a: 'تدعم المنصة محافظات جمهورية مصر العربية (مثل القاهرة، الجيزة، الإسكندرية والمحافظات الأخرى) وتتوسع باستمرار بناءً على أماكن عمل الكوادر التمريضية المسجلة.',
    faq4_q: 'هل المنصة بديل عن خدمات الطوارئ؟',
    faq4_a: 'لا، منصة رعايه مخصصة للرعاية التمريضية المجدولة والزيارات المنزلية المحددة مسبقاً، ولا تتعامل مع الحالات الحرجة. في الطوارئ يرجى الاتصال فوراً بالإسعاف المصري على 123.',
    faq5_q: 'كيف يتم التحقق من مؤهلات الممرض؟',
    faq5_a: 'يتم مراجعة بيانات الاعتماد والتسجيل المهني للممرضين ومؤهلاتهم قبل منحهم شارة التوثيق في المنصة، ويمكن للمريض مراجعة تفاصيل الخبرة في الملف الشخصي.',
    view_all_faqs: 'عرض جميع الأسئلة الشائعة ←',

    // Contact & Inquiry
    contact_title: 'تواصل معنا',
    contact_subtitle: 'نحن هنا لمساعدتك في أي استفسار حول خدمات الرعاية التمريضية المنزلية',
    contact_email: 'البريد الإلكتروني الرسمي',
    contact_phone: 'مركز خدمة المستفيدين',
    contact_address: 'نطاق الخدمة',
    contact_address_val: 'محافظات الدقهلية، البحيرة، الغربية، الفيوم وبني سويف',
    contact_form_title: 'أرسل استفسارك',
    contact_form_desc: 'نسعد بالإجابة عن تساؤلاتك ومساعدتك في اختيار الخدمة المناسبة.',
    contact_name: 'الاسم بالكامل',
    contact_phone_field: 'رقم الهاتف (مصري)',
    contact_subject: 'موضوع الاستفسار',
    contact_message: 'نص الرسالة أو الاستفسار',
    contact_send: 'إرسال الاستفسار',
    contact_subj_general: 'استفسار عام عن الخدمات',
    contact_subj_nurse: 'الانضمام ككادر تمريضي',
    contact_subj_booking: 'مساعدة في حجز زيارة',
    contact_subj_complaint: 'اقتراح أو ملاحظة',

    // CTA
    cta_nurse_title: 'هل أنت ممرض/ة مؤهل/ة؟',
    cta_nurse_desc: 'انضم إلى شبكة رعايه لتقديم الرعاية المنزلية للمرضى في محافظتك وزيادة دخلك المهني.',
    cta_join_nurse: '🏥 انضم ككادر تمريضي الآن',
    cta_join_patient: '👤 سجّل كمريض',

    // Footer
    footer_desc: 'منصة رعايه تربط المرضى بالكوادر التمريضية المؤهلة لتقديم خدمات الرعاية الصحية والتمريض المنزلي بأعلى معايير الجودة والأمان.',
    footer_services: 'الخدمات التمريضية',
    footer_useful_links: 'روابط هامة',
    footer_account: 'الحساب',
    footer_rights: 'جميع الحقوق محفوظة.',
    footer_privacy: 'سياسة الخصوصية',
    footer_terms: 'الشروط والأحكام',
    patient_dashboard: 'لوحة المريض',
    nurse_dashboard: 'لوحة الممرض',

    // Auth
    auth_full_name: 'الاسم الكامل',
    auth_email: 'البريد الإلكتروني',
    auth_phone: 'رقم الهاتف',
    auth_password: 'كلمة المرور',
    auth_confirm_password: 'تأكيد كلمة المرور',
    auth_account_type: 'نوع الحساب',
    auth_patient: 'مريض',
    auth_nurse: 'ممرض/ممرضة',
    auth_login: 'تسجيل الدخول',
    auth_register: 'إنشاء حساب',
    auth_forgot_password: 'نسيت كلمة المرور؟',
    auth_have_account: 'لديك حساب بالفعل؟',
    auth_no_account: 'ليس لديك حساب؟',
    auth_reset_password: 'إعادة تعيين كلمة المرور',
    auth_send_reset: 'إرسال رابط الاستعادة',

    // Misc
    loading: 'جاري التحميل...',
    error_generic: 'حدث خطأ غير متوقع. يرجى المحاولة مرة أخرى.',
    success_saved: 'تم الحفظ بنجاح',
    no_data: 'لا توجد بيانات متاحة حالياً',
    lang_toggle: 'English',
  },

  en: {
    // Top Emergency Banner
    emergency_label: 'Urgent Medical Notice',
    emergency_notice: 'Raaya is dedicated to scheduled home nursing care and does not replace emergency medical services. In life-threatening emergencies, please call the Egyptian Ambulance immediately.',
    emergency_call: 'Egypt Ambulance 123',

    // Navigation
    nav_home: 'Home',
    nav_nurses: 'Nurses',
    nav_how_it_works: 'How It Works',
    nav_faq: 'FAQ',
    nav_contact: 'Contact',
    nav_login: 'Login',
    nav_register: 'Register',
    nav_dashboard: 'Dashboard',
    nav_profile: 'Profile',
    nav_logout: 'Logout',

    // Hero
    hero_badge: 'Home Nursing & Healthcare Platform in Egypt',
    hero_title: 'Professional Nursing',
    hero_title_2: 'Care at Your Home',
    hero_subtitle: 'Connecting you with qualified nursing professionals for healthcare in the comfort and safety of your home',
    hero_book_nurse: 'Book a Nurse',
    hero_find_nurse: 'Find a Nurse',
    stat_nurses: 'Nursing Staff',
    stat_governorates: 'Governorates',
    stat_home_care: 'Home Care',

    // Services
    services_title: 'Our Nursing Services',
    services_subtitle: 'We provide specialized home nursing services delivered by qualified practitioners',
    service_wound: 'Wound Care',
    service_wound_desc: 'Sterile dressing changes, wound management, and pressure ulcer care',
    service_injection: 'Injections & IVs',
    service_injection_desc: 'Accurate and safe intramuscular, subcutaneous, and intravenous therapies',
    service_elderly: 'Elderly Care',
    service_elderly_desc: 'Comprehensive compassionate assistance and health monitoring for seniors',
    service_postop: 'Post-Operative',
    service_postop_desc: 'Recovery monitoring, vital signs checks, and surgical rehabilitation support',
    service_baby: 'Pediatric Care',
    service_baby_desc: 'Specialized healthcare for infants and newborns with guidance for parents',
    service_physiotherapy: 'Physiotherapy',
    service_physiotherapy_desc: 'In-home physical therapy sessions and mobility rehabilitation',

    // How it works
    how_title: 'How Does CareNest Work?',
    how_step1_title: 'Create Your Account',
    how_step1_desc: 'Register easily as a patient to request visits or as a nurse to provide care',
    how_step2_title: 'Choose a Nurse',
    how_step2_desc: 'Browse nurses filtered by Egyptian governorate, specialty, and verified reviews',
    how_step3_title: 'Set Date & Address',
    how_step3_desc: 'Select your service, preferred schedule, and visit address to send your booking',
    how_step4_title: 'Receive Care',
    how_step4_desc: 'Your qualified nurse arrives promptly and delivers personalized medical care',

    // Featured Nurses
    nurses_title: 'Available Nurses',
    nurses_subtitle: 'Browse qualified registered nurses in Egypt',
    view_all_nurses: 'View All Nurses →',

    // Nurses Directory Page
    nurses_header_title: 'Find the Right Nurse for Your Home Care',
    nurses_header_subtitle: 'Browse qualified nursing staff available for specialized home visits in your governorate',
    filter_search_label: 'Quick Search',
    filter_search_placeholder: '🔍 Search by nurse name, specialty, or city...',
    filter_gov_label: 'Governorate',
    filter_gov_all: 'All Egyptian Governorates',
    filter_city_label: 'City / Area',
    filter_city_placeholder: 'Select governorate first',
    filter_specialty_label: 'Specialty',
    filter_specialty_all: 'All Specialties',
    filter_price_label: 'Max Visit Price',
    filter_price_any: 'Any Price',
    filter_reset_btn: 'Reset Filters',
    nurses_available_title: 'Available Nurses',
    nurses_count_suffix: 'available nurses',
    nurse_exp_label: 'Experience',
    nurse_exp_years: 'years',
    nurse_price_label: 'Visit Price',
    nurse_price_per_visit: 'EGP / visit',
    not_specified: 'Not specified yet',
    status_verified: '✓ Verified',
    status_pending: '⏳ Under Review',
    status_unavailable: 'Status Unavailable',
    btn_view_profile: 'View Profile',
    btn_book_visit: '📅 Book Visit',
    nurse_modal_title: 'Nurse Professional Profile',
    nurse_modal_bio: 'Professional Bio',
    nurse_modal_qualifications: 'Qualifications & Credentials',
    nurse_modal_location: 'Service Area',
    nurse_modal_close: 'Close',
    empty_no_nurses: 'No nurses currently available in database',
    empty_no_matches: 'No nurses match your search criteria',
    empty_no_matches_desc: 'Try adjusting your filters, changing the governorate, or resetting filters.',
    error_fetch_nurses: 'Failed to load nurse data from database',
    btn_retry: 'Retry 🔄',

    // Reviews
    reviews_title: 'Patient Reviews',
    reviews_subtitle: 'Authentic reviews and ratings published by verified patients after home visits',

    // FAQ
    faq_title: 'Frequently Asked Questions',
    faq1_q: 'How do I register an account on CareNest?',
    faq1_a: 'Click "Register" at the top of the page, select Patient or Nurse, and submit your basic information and Egyptian phone number to get started.',
    faq2_q: 'How do I book a home nursing visit?',
    faq2_a: 'After logging in, browse the nurse catalog, select the nurse that matches your governorate and required specialty, and schedule your appointment.',
    faq3_q: 'Which Egyptian governorates are supported?',
    faq3_a: 'CareNest covers Cairo, Giza, Alexandria, and governorates across Egypt based on active local nursing availability.',
    faq4_q: 'Does CareNest handle medical emergencies?',
    faq4_a: 'No. CareNest is exclusively for scheduled home care. In critical medical emergencies, please dial the Egyptian Ambulance Service immediately at 123.',
    faq5_q: 'How are nurses verified?',
    faq5_a: 'Nurses displaying a verified badge have undergone review of their identity and credentials to ensure trusted home medical care.',
    view_all_faqs: 'View All FAQs →',

    // Contact & Inquiry
    contact_title: 'Contact Us',
    contact_subtitle: 'We are here to answer your questions and assist with home nursing arrangements',
    contact_email: 'Official Support Email',
    contact_phone: 'Customer Assistance',
    contact_address: 'Coverage Area',
    contact_address_val: 'Arab Republic of Egypt (Cairo, Giza, Alexandria & all Governorates)',
    contact_form_title: 'Send an Inquiry',
    contact_form_desc: 'We are glad to answer questions and help you select the appropriate home care service.',
    contact_name: 'Full Name',
    contact_phone_field: 'Phone Number (Egypt)',
    contact_subject: 'Inquiry Subject',
    contact_message: 'Message / Inquiry Details',
    contact_send: 'Send Inquiry',
    contact_subj_general: 'General Service Inquiry',
    contact_subj_nurse: 'Join as Nursing Cadre',
    contact_subj_booking: 'Booking Assistance',
    contact_subj_complaint: 'Feedback or Suggestion',

    // CTA
    cta_nurse_title: 'Are You a Qualified Nurse?',
    cta_nurse_desc: 'Join the CareNest network to provide home healthcare in your governorate and grow professionally.',
    cta_join_nurse: '🏥 Join as Nurse Now',
    cta_join_patient: '👤 Register as Patient',

    // Footer
    footer_desc: 'CareNest connects patients with qualified nursing professionals for high-quality, trusted home healthcare across Egypt.',
    footer_services: 'Nursing Services',
    footer_useful_links: 'Important Links',
    footer_account: 'Account',
    footer_rights: 'All rights reserved.',
    footer_privacy: 'Privacy Policy',
    footer_terms: 'Terms & Conditions',

    // Auth
    auth_full_name: 'Full Name',
    auth_email: 'Email Address',
    auth_phone: 'Phone Number',
    auth_password: 'Password',
    auth_confirm_password: 'Confirm Password',
    auth_account_type: 'Account Type',
    auth_patient: 'Patient',
    auth_nurse: 'Nurse',
    auth_login: 'Login',
    auth_register: 'Create Account',
    auth_forgot_password: 'Forgot your password?',
    auth_have_account: 'Already have an account?',
    auth_no_account: "Don't have an account?",
    auth_reset_password: 'Reset Password',
    auth_send_reset: 'Send Reset Link',

    // Misc
    loading: 'Loading...',
    error_generic: 'An unexpected error occurred. Please try again.',
    success_saved: 'Saved successfully',
    no_data: 'No data currently available',
    lang_toggle: 'عربي',
  }
};

// ============================================================
// i18n Engine
// ============================================================
const i18n = {
  currentLang: (typeof localStorage !== 'undefined' ? (localStorage.getItem('raaya_lang') || localStorage.getItem('carenest_lang')) : null) || 'ar',

  t(key) {
    return (TRANSLATIONS[this.currentLang] && TRANSLATIONS[this.currentLang][key]) || 
           (TRANSLATIONS.ar && TRANSLATIONS.ar[key]) || 
           key;
  },

  setLang(lang) {
    this.currentLang = lang;
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem('raaya_lang', lang);
      localStorage.setItem('carenest_lang', lang);
    }
    if (typeof document !== 'undefined') {
      document.documentElement.lang = lang;
      document.documentElement.dir = lang === 'ar' ? 'rtl' : 'ltr';
    }
    this.applyTranslations();
  },

  toggleLang() {
    this.setLang(this.currentLang === 'ar' ? 'en' : 'ar');
  },

  applyTranslations() {
    document.querySelectorAll('[data-i18n]').forEach(el => {
      const key = el.getAttribute('data-i18n');
      const translation = this.t(key);
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        el.placeholder = translation;
      } else {
        el.textContent = translation;
      }
    });

    document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
      el.placeholder = this.t(el.getAttribute('data-i18n-placeholder'));
    });

    document.querySelectorAll('[data-i18n-title]').forEach(el => {
      el.title = this.t(el.getAttribute('data-i18n-title'));
    });

    // Update lang toggle buttons
    document.querySelectorAll('.lang-toggle').forEach(btn => {
      btn.textContent = this.t('lang_toggle');
    });

    // Dispatch event for components that need to re-render
    document.dispatchEvent(new CustomEvent('langChanged', { detail: { lang: this.currentLang } }));
  },

  init() {
    document.documentElement.lang = this.currentLang;
    document.documentElement.dir = this.currentLang === 'ar' ? 'rtl' : 'ltr';
    this.applyTranslations();
    document.querySelectorAll('.lang-toggle').forEach(btn => {
      btn.addEventListener('click', () => this.toggleLang());
    });
  }
};

if (typeof window !== 'undefined') {
  window.i18n = i18n;
  window.TRANSLATIONS = TRANSLATIONS;
}
