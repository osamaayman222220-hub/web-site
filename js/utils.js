// ============================================================
// رعايه | CareNest - Shared Utilities
// ============================================================

// ── HTML Sanitization & XSS Protection Helpers ──
function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function sanitizeUrl(url) {
  if (!url || typeof url !== 'string') return '#';
  const clean = url.trim();
  // Prevent script execution schemes (javascript:, vbscript:, data:text/html, etc.)
  if (/^\s*(javascript|vbscript|data\s*:)/i.test(clean)) {
    return '#';
  }
  // Allow safe protocols & relative paths
  if (
    clean.startsWith('/') ||
    clean.startsWith('./') ||
    clean.startsWith('../') ||
    clean.startsWith('http://') ||
    clean.startsWith('https://') ||
    clean.startsWith('tel:') ||
    clean.startsWith('mailto:') ||
    clean.startsWith('https://wa.me/')
  ) {
    return clean;
  }
  return '#';
}

if (typeof window !== 'undefined') {
  window.escapeHtml = escapeHtml;
  window.sanitizeUrl = sanitizeUrl;
}

// ── Toast Notification System ──
const Toast = {
  container: null,

  init() {
    this.container = document.getElementById('toast-container');
    if (!this.container) {
      this.container = document.createElement('div');
      this.container.id = 'toast-container';
      this.container.className = 'toast-container';
      document.body.appendChild(this.container);
    }
  },

  show(message, type = 'info', duration = 4000) {
    if (!this.container) this.init();
    const icons = { success: '✅', error: '❌', warning: '⚠️', info: 'ℹ️' };
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    
    // Safely construct toast without risking HTML injection from message
    const iconSpan = document.createElement('span');
    iconSpan.className = 'toast-icon';
    iconSpan.textContent = icons[type] || icons.info;

    const msgSpan = document.createElement('span');
    msgSpan.className = 'toast-message';
    msgSpan.textContent = String(message || '');

    const closeBtn = document.createElement('button');
    closeBtn.className = 'toast-close';
    closeBtn.setAttribute('aria-label', 'Close');
    closeBtn.textContent = '✕';
    closeBtn.addEventListener('click', () => this.remove(toast));

    toast.appendChild(iconSpan);
    toast.appendChild(msgSpan);
    toast.appendChild(closeBtn);

    this.container.appendChild(toast);
    if (duration > 0) setTimeout(() => this.remove(toast), duration);
    return toast;
  },

  remove(toast) {
    toast.style.animation = 'none';
    toast.style.opacity = '0';
    toast.style.transform = 'translateX(100%)';
    toast.style.transition = 'all 0.3s ease';
    setTimeout(() => toast.remove(), 300);
  },

  success(msg, duration) { return this.show(msg, 'success', duration); },
  error(msg, duration) { return this.show(msg, 'error', duration); },
  warning(msg, duration) { return this.show(msg, 'warning', duration); },
  info(msg, duration) { return this.show(msg, 'info', duration); },
};

// ── Form Validation ──
const Validator = {
  rules: {
    required: (v) => v.trim().length > 0 || 'This field is required / هذا الحقل مطلوب',
    email: (v) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) || 'Please enter a valid email / أدخل بريدًا إلكترونيًا صحيحًا',
    phone: (v) => {
      if (!v.trim()) return true;
      if (typeof EgyptLocations !== 'undefined') {
        return EgyptLocations.validateEgyptianPhone(v) || 'يرجى إدخال رقم هاتف مصري صحيح (مثال: 01012345678 أو +201012345678) / Please enter a valid Egyptian phone number';
      }
      return /^(\+20|0020|20|0)?1[0125][0-9]{8}$/.test(v.replace(/[\s\-\(\)]/g, '')) || 'يرجى إدخال رقم هاتف مصري صحيح (مثال: 01012345678) / Please enter a valid Egyptian phone number';
    },
    minLength: (min) => (v) => v.length >= min || `Minimum ${min} characters / ${min} أحرف على الأقل`,
    maxLength: (max) => (v) => v.length <= max || `Maximum ${max} characters / ${max} أحرف كحد أقصى`,
    passwordStrength: (v) => /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$/.test(v) ||
      'Password must be at least 8 characters with uppercase, lowercase, and number',
    match: (other) => (v) => v === other || 'Passwords do not match / كلمات المرور غير متطابقة',
  },

  validate(form) {
    let isValid = true;
    form.querySelectorAll('[data-validate]').forEach(field => {
      const rules = field.getAttribute('data-validate').split(',').map(r => r.trim());
      const error = this._checkRules(field.value, rules, form);
      this._showError(field, error);
      if (error) isValid = false;
    });
    return isValid;
  },

  _checkRules(value, rules, form) {
    for (const rule of rules) {
      if (rule === 'required') {
        const result = this.rules.required(value);
        if (result !== true) return result;
      } else if (rule === 'email') {
        if (value.trim()) {
          const result = this.rules.email(value);
          if (result !== true) return result;
        }
      } else if (rule === 'phone') {
        if (value.trim()) {
          const result = this.rules.phone(value);
          if (result !== true) return result;
        }
      } else if (rule === 'password') {
        if (value.trim()) {
          const result = this.rules.passwordStrength(value);
          if (result !== true) return result;
        }
      } else if (rule.startsWith('min:')) {
        const min = parseInt(rule.split(':')[1]);
        const result = this.rules.minLength(min)(value);
        if (result !== true) return result;
      } else if (rule.startsWith('match:')) {
        const otherId = rule.split(':')[1];
        const other = form.querySelector(`#${otherId}`)?.value || '';
        const result = this.rules.match(other)(value);
        if (result !== true) return result;
      }
    }
    return null;
  },

  _showError(field, error) {
    field.classList.toggle('error', !!error);
    const errorEl = field.closest('.form-group')?.querySelector('.form-error');
    if (errorEl) {
      errorEl.textContent = error || '';
      errorEl.classList.toggle('visible', !!error);
    }
  },

  clearErrors(form) {
    form.querySelectorAll('.form-control').forEach(f => {
      f.classList.remove('error');
    });
    form.querySelectorAll('.form-error').forEach(e => {
      e.classList.remove('visible');
      e.textContent = '';
    });
  }
};

// ── Loading Button Helper ──
function setButtonLoading(btn, isLoading) {
  if (isLoading) {
    btn._originalText = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<div class="spinner"></div>';
  } else {
    btn.disabled = false;
    btn.innerHTML = btn._originalText || btn.innerHTML;
  }
}

// ── Date & Time Utilities ──
const DateUtils = {
  format(dateStr, lang = 'ar') {
    if (!dateStr) return '—';
    const date = new Date(dateStr);
    const opts = { year: 'numeric', month: 'long', day: 'numeric' };
    return date.toLocaleDateString(lang === 'ar' ? 'ar-SA' : 'en-US', opts);
  },

  formatTime(timeStr) {
    if (!timeStr) return '—';
    const [h, m] = timeStr.split(':');
    const hour = parseInt(h);
    const ampm = hour >= 12 ? 'م' : 'ص';
    const h12 = hour % 12 || 12;
    return `${h12}:${m} ${ampm}`;
  },

  formatRelative(dateStr, lang = 'ar') {
    if (!dateStr) return '—';
    const date = new Date(dateStr);
    const now = new Date();
    const diff = now - date;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    if (lang === 'ar') {
      if (minutes < 1) return 'الآن';
      if (minutes < 60) return `منذ ${minutes} دقيقة`;
      if (hours < 24) return `منذ ${hours} ساعة`;
      if (days < 7) return `منذ ${days} يوم`;
      return this.format(dateStr, 'ar');
    } else {
      if (minutes < 1) return 'just now';
      if (minutes < 60) return `${minutes}m ago`;
      if (hours < 24) return `${hours}h ago`;
      if (days < 7) return `${days}d ago`;
      return this.format(dateStr, 'en');
    }
  },

  isPastDate(dateStr) {
    return new Date(dateStr) < new Date();
  },

  todayStr() {
    return new Date().toISOString().split('T')[0];
  }
};

// ── DOM Utilities ──
const DOM = {
  qs: (selector, parent = document) => parent.querySelector(selector),
  qsa: (selector, parent = document) => [...parent.querySelectorAll(selector)],

  show(el) { if (el) el.classList.remove('hidden'); },
  hide(el) { if (el) el.classList.add('hidden'); },
  toggle(el) { if (el) el.classList.toggle('hidden'); },

  setText(selector, text) {
    const el = this.qs(selector);
    if (el) el.textContent = text;
  },

  setHTML(selector, html) {
    const el = this.qs(selector);
    if (el) el.innerHTML = html;
  },

  on(el, event, handler) {
    if (el) el.addEventListener(event, handler);
  }
};

// ── Status Badge Helper ──
function getStatusBadge(status, lang = 'ar') {
  const labels = {
    ar: {
      pending: 'قيد الانتظار', accepted: 'مقبول', rejected: 'مرفوض',
      in_progress: 'جارٍ التنفيذ', completed: 'مكتمل', cancelled: 'ملغى'
    },
    en: {
      pending: 'Pending', accepted: 'Accepted', rejected: 'Rejected',
      in_progress: 'In Progress', completed: 'Completed', cancelled: 'Cancelled'
    }
  };
  const label = labels[lang]?.[status] || status;
  return `<span class="status-badge status-${status}">${label}</span>`;
}

// ── Stars Display ──
function renderStars(rating, max = 5) {
  let html = '<span class="stars-display">';
  for (let i = 1; i <= max; i++) {
    html += i <= rating ? '⭐' : '☆';
  }
  html += '</span>';
  return html;
}

// ── Navbar Scroll Effect ──
function initNavbarScroll() {
  const navbar = document.querySelector('.navbar');
  if (!navbar) return;
  window.addEventListener('scroll', () => {
    navbar.classList.toggle('scrolled', window.scrollY > 20);
  });
}

// ── Mobile Menu ──
function initMobileMenu() {
  const hamburger = document.getElementById('hamburger');
  const nav = document.getElementById('main-nav');
  if (!hamburger || !nav) return;

  function closeMenu() {
    nav.classList.remove('open');
    hamburger.classList.remove('active');
    hamburger.setAttribute('aria-expanded', 'false');
    hamburger.setAttribute('aria-label', (typeof i18n !== 'undefined' && i18n.currentLang === 'en') ? 'Open navigation menu' : 'فتح القائمة');
  }

  function openMenu() {
    nav.classList.add('open');
    hamburger.classList.add('active');
    hamburger.setAttribute('aria-expanded', 'true');
    hamburger.setAttribute('aria-label', (typeof i18n !== 'undefined' && i18n.currentLang === 'en') ? 'Close navigation menu' : 'إغلاق القائمة');
  }

  hamburger.addEventListener('click', () => {
    const isOpen = nav.classList.contains('open');
    if (isOpen) {
      closeMenu();
    } else {
      openMenu();
    }
  });

  // Close when clicking any nav link
  nav.querySelectorAll('a').forEach(link => {
    link.addEventListener('click', () => {
      if (window.innerWidth <= 768) {
        closeMenu();
      }
    });
  });

  // Close on outside click
  document.addEventListener('click', (e) => {
    if (!hamburger.contains(e.target) && !nav.contains(e.target) && nav.classList.contains('open')) {
      closeMenu();
    }
  });

  // Close on Escape key
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && nav.classList.contains('open')) {
      closeMenu();
      hamburger.focus();
    }
  });
}

// ── FAQ Accordion ──
function initFAQ() {
  const items = document.querySelectorAll('.faq-item');
  items.forEach(item => {
    const question = item.querySelector('.faq-question');
    if (!question) return;

    function toggle() {
      const willOpen = !item.classList.contains('open');

      // Close all other items and update their aria-expanded
      items.forEach(i => {
        i.classList.remove('open');
        const q = i.querySelector('.faq-question');
        const icon = i.querySelector('.faq-icon');
        if (q) q.setAttribute('aria-expanded', 'false');
        if (icon) icon.textContent = '+';
      });

      if (willOpen) {
        item.classList.add('open');
        question.setAttribute('aria-expanded', 'true');
        const icon = item.querySelector('.faq-icon');
        if (icon) icon.textContent = '−';
      }
    }

    question.addEventListener('click', toggle);

    // Keyboard support for Enter and Space
    question.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        toggle();
      }
    });
  });
}

// ── Tabs ──
function initTabs(containerSelector = '.tabs') {
  document.querySelectorAll(containerSelector).forEach(tabGroup => {
    tabGroup.querySelectorAll('.tab-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const target = btn.getAttribute('data-tab');
        // Update buttons
        tabGroup.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        // Update panels
        const panelContainer = tabGroup.closest('.tabs-container') || document;
        panelContainer.querySelectorAll('.tab-content').forEach(p => {
          p.classList.toggle('active', p.id === target);
        });
      });
    });
  });
}

// ── Modal ──
function initModals() {
  document.querySelectorAll('[data-modal-open]').forEach(btn => {
    btn.addEventListener('click', () => {
      const modal = document.getElementById(btn.getAttribute('data-modal-open'));
      modal?.classList.add('open');
    });
  });
  document.querySelectorAll('[data-modal-close], .modal-overlay').forEach(el => {
    el.addEventListener('click', (e) => {
      if (el.classList.contains('modal-overlay') && e.target !== el) return;
      const overlay = el.closest('.modal-overlay') || document.getElementById(el.getAttribute('data-modal-close'));
      overlay?.classList.remove('open');
    });
  });
}

// ── Scroll Reveal ──
function initScrollReveal() {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        e.target.classList.add('visible');
        observer.unobserve(e.target);
      }
    });
  }, { threshold: 0.1 });
  document.querySelectorAll('.reveal').forEach(el => observer.observe(el));
}

// ── Avatar Upload Preview ──
function initAvatarUpload(inputId, previewId) {
  const input = document.getElementById(inputId);
  const preview = document.getElementById(previewId);
  if (!input || !preview) return;
  input.addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const maxSize = (CARENEST_CONFIG?.app?.maxUploadSizeMB || 5) * 1024 * 1024;
    const allowedTypes = CARENEST_CONFIG?.app?.allowedImageTypes || ['image/jpeg', 'image/png', 'image/webp'];
    if (!allowedTypes.includes(file.type)) {
      Toast.error('Invalid file type. Please use JPG, PNG, or WebP.');
      return;
    }
    if (file.size > maxSize) {
      Toast.error(`File too large. Maximum size is ${CARENEST_CONFIG?.app?.maxUploadSizeMB || 5}MB.`);
      return;
    }
    const reader = new FileReader();
    reader.onload = (ev) => {
      if (preview.tagName === 'IMG') {
        preview.src = ev.target.result;
      } else {
        preview.style.backgroundImage = `url(${ev.target.result})`;
        preview.innerHTML = `<img src="${ev.target.result}" alt="Preview">`;
      }
    };
    reader.readAsDataURL(file);
  });
}

// ── User Avatar Initial ──
function getAvatarInitial(name) {
  if (!name) return '?';
  const parts = name.trim().split(/\s+/);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return name[0].toUpperCase();
}

// ── Sidebar Mobile Toggle ──
function initSidebarToggle() {
  const btn = document.getElementById('sidebar-toggle');
  const sidebar = document.getElementById('sidebar');
  if (!btn || !sidebar) return;
  btn.addEventListener('click', () => sidebar.classList.toggle('open'));
  // Close on overlay click
  const overlay = document.getElementById('sidebar-overlay');
  overlay?.addEventListener('click', () => sidebar.classList.remove('open'));
}

// ── Central Customer Support & Social Links ──
function initCustomerSupportSocial() {
  const cfg = (typeof CARENEST_CONFIG !== 'undefined' ? CARENEST_CONFIG.social : null) || {};

  function normalizeWhatsappUrl(val) {
    if (!val || typeof val !== 'string') return '';
    const clean = val.trim();
    if (clean.startsWith('http://') || clean.startsWith('https://')) return clean;
    const digits = clean.replace(/\D/g, '');
    if (!digits) return '';
    const standardDigits = digits.startsWith('0') ? '2' + digits : (digits.startsWith('20') ? digits : '20' + digits);
    return `https://wa.me/${standardDigits}`;
  }

  const whatsappUrl = normalizeWhatsappUrl(cfg.whatsapp);
  const facebookUrl = (cfg.facebook && typeof cfg.facebook === 'string' && cfg.facebook.trim().startsWith('http')) ? cfg.facebook.trim() : '';
  const instagramUrl = (cfg.instagram && typeof cfg.instagram === 'string' && cfg.instagram.trim().startsWith('http')) ? cfg.instagram.trim() : '';

  // Update existing social link elements in DOM
  const links = [
    { id: 'whatsapp-link', url: whatsappUrl },
    { id: 'facebook-link', url: facebookUrl },
    { id: 'instagram-link', url: instagramUrl }
  ];

  // ─── تحديث روابط التواصل الداخلية في الفوتر (إن وُجدت) ───
  // لا نُظهر #contact-social-links لأن الأيقونات العائمة على اليسار تُغطي هذا
  const contactSocialWrap = document.getElementById('contact-social-links');
  if (contactSocialWrap) {
    contactSocialWrap.style.display = 'none';
  }

  // ─── تحديث href للروابط الفردية إن وُجدت ─────────────────────
  links.forEach(({ id, url }) => {
    const el = document.getElementById(id);
    if (el && url) {
      el.href = url;
      el.target = '_blank';
      el.rel = 'noopener noreferrer';
    }
  });

  // ملاحظة: أيقونات التواصل العائمة تُنشأ بواسطة whatsapp.js فقط
  // ولا يتم إنشاؤها هنا لتجنب التكرار على الجانب الأيمن (inset-inline-start في RTL)
}

// ── Init All (call on page load) ──
function initCommon() {
  Toast.init();
  initNavbarScroll();
  initMobileMenu();
  initFAQ();
  initTabs();
  initModals();
  initScrollReveal();
  initSidebarToggle();
  initCustomerSupportSocial();
  if (typeof i18n !== 'undefined') i18n.init();
}

// Auto-init
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initCommon);
} else {
  initCommon();
}
