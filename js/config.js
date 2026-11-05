// ============================================================
// رعايه | CareNest - Configuration File
// Egypt Configuration
// ============================================================

(function (window) {
  'use strict';

  const CARENEST_CONFIG = {
    supabase: {
      // Supabase Project URL
      url: 'https://tfolrgauojmbeofartaq.supabase.co',

      // Public browser key only.
      // Never put service_role or secret keys in frontend code.
      anonKey: 'sb_publishable_kZ_9fmxv6HTpNg9Ual_LWA_WG_tJNeF'
    },

    country: {
      code: 'EG',
      nameAr: 'مصر',
      nameEn: 'Egypt',
      currencyCode: 'EGP',
      currencySymbolAr: 'ج.م',
      currencyNameAr: 'جنيه مصري',
      currencySymbolEn: 'EGP',
      currencyNameEn: 'Egyptian Pound',
      phonePrefix: '+20',
      emergencyPhone: '123',
      defaultGovernorate: '',
      defaultCity: ''
    },

    // إعدادات خدمة العملاء والتواصل الموحدة لمنصة CareNest
    social: {
      whatsapp: '201097729492',
      facebook: 'https://www.facebook.com/share/1CcDC3kHQy/',
      instagram: 'https://www.instagram.com/re3aya.eg?exln=bXB3OWpmMnpkNXpl'
    },

    map: {
      defaultCenter: [30.0444, 31.2357],
      defaultZoom: 11,
      bounds: {
        minLat: 22.0,
        maxLat: 31.7,
        minLng: 25.0,
        maxLng: 36.9
      }
    },

    app: {
      name: 'كير نست',
      nameEn: 'CareNest',
      supportEmail: 'support@carenest.app',
      // عنوان الموقع بعد النشر — اتركه فارغاً أثناء التطوير المحلي
      // مثال بعد النشر: 'https://carenest.app'
      siteUrl: 'http://localhost:55645',
      maxUploadSizeMB: 5,
      allowedImageTypes: [
        'image/jpeg',
        'image/png',
        'image/webp'
      ],
      allowedDocTypes: [
        'application/pdf',
        'image/jpeg',
        'image/png'
      ]
    }
  };

  // Expose configuration globally for traditional scripts.
  window.CARENEST_CONFIG = CARENEST_CONFIG;
  window.RAAYA_CONFIG = CARENEST_CONFIG;

  // Validate configuration.
  const supabaseConfig = CARENEST_CONFIG.supabase;

  if (
    !supabaseConfig.url ||
    !supabaseConfig.anonKey ||
    supabaseConfig.url.includes('YOUR_') ||
    supabaseConfig.anonKey.includes('YOUR_')
  ) {
    console.error(
      'رعايه: إعدادات Supabase غير مكتملة. راجع js/config.js'
    );
  } else {
    console.log('رعايه: تم تحميل الإعدادات بنجاح.');
  }

})(window);
