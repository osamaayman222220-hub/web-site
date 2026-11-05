// ============================================================
// رعايه | CareNest - Central Floating Social & WhatsApp Script
// ============================================================

(function () {
  'use strict';

  // 1. التأكد من تحميل مكتبة Font Awesome للأيقونات
  function ensureFontAwesome() {
    const existing = document.querySelector('link[href*="font-awesome"], link[href*="fontawesome"]');
    if (!existing) {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = 'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css';
      link.crossOrigin = 'anonymous';
      link.referrerPolicy = 'no-referrer';
      document.head.appendChild(link);
    }
  }

  // 2. إضافة أيقونات التواصل الاجتماعي (Facebook & Instagram)
  function initSocialIcons() {
    if (document.querySelector('.reaya-social-icons')) return;

    // استخراج الروابط من إعدادات المشروع إن وجدت، أو استخدام الروابط الرسمية المعتمدة
    const cfg = (typeof CARENEST_CONFIG !== 'undefined' && CARENEST_CONFIG.social) ? CARENEST_CONFIG.social : {};
    const fbUrl = (cfg.facebook && cfg.facebook.trim().startsWith('http')) 
      ? cfg.facebook.trim() 
      : 'https://www.facebook.com/share/1CcDC3kHQy/';

    const igUrl = (cfg.instagram && cfg.instagram.trim().startsWith('http')) 
      ? cfg.instagram.trim() 
      : 'https://www.instagram.com/re3aya.eg?exln=bXB3OWpmMnpkNXpl';

    const container = document.createElement('div');
    container.className = 'reaya-social-icons';
    container.setAttribute('aria-label', 'حسابات التواصل الاجتماعي');

    container.innerHTML = `
      <a href="${fbUrl}"
         class="facebook-icon"
         target="_blank"
         rel="noopener noreferrer"
         aria-label="Facebook"
         title="صفحتنا على فيسبوك">
        <i class="fa-brands fa-facebook-f" aria-hidden="true"></i>
      </a>
      <a href="${igUrl}"
         class="instagram-icon"
         target="_blank"
         rel="noopener noreferrer"
         aria-label="Instagram"
         title="حسابنا على إنستغرام">
        <i class="fa-brands fa-instagram" aria-hidden="true"></i>
      </a>
    `;

    document.body.appendChild(container);
  }

  // 3. إضافة زر WhatsApp العائم
  function initWhatsAppButton() {
    if (document.querySelector('.floating-whatsapp')) return;

    // رقم خدمة العملاء الحقيقي المعتمد بمشروع CareNest
    const cfg = (typeof CARENEST_CONFIG !== 'undefined' && CARENEST_CONFIG.social) ? CARENEST_CONFIG.social : {};
    let waUrl = 'https://wa.me/201097729492';

    if (cfg.whatsapp && typeof cfg.whatsapp === 'string') {
      const clean = cfg.whatsapp.trim();
      if (clean.startsWith('http://') || clean.startsWith('https://')) {
        waUrl = clean;
      } else {
        const digits = clean.replace(/\D/g, '');
        if (digits) {
          const standard = digits.startsWith('0') ? '2' + digits : (digits.startsWith('20') ? digits : '20' + digits);
          waUrl = `https://wa.me/${standard}`;
        }
      }
    }

    const whatsapp = document.createElement('a');
    whatsapp.href = waUrl;
    whatsapp.target = '_blank';
    whatsapp.rel = 'noopener noreferrer';
    whatsapp.className = 'floating-whatsapp';
    whatsapp.setAttribute('aria-label', 'تواصل معنا عبر واتساب');
    whatsapp.setAttribute('title', 'تواصل معنا عبر واتساب');

    whatsapp.innerHTML = '<i class="fa-brands fa-whatsapp" aria-hidden="true"></i>';

    document.body.appendChild(whatsapp);
  }

  function initWidgets() {
    ensureFontAwesome();
    initSocialIcons();
    initWhatsAppButton();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initWidgets);
  } else {
    initWidgets();
  }
})();

