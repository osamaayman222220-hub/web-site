// ============================================================
// CareNest - Authentication Module
// js/auth.js
// ============================================================

(function (window) {
  'use strict';

  const MIN_PASSWORD_LENGTH = 8;
  const NATIONAL_ID_FUNCTION = 'save-national-id';

  function getClient() {
    if (typeof window.getSupabase === 'function') {
      return window.getSupabase();
    }

    return window.supabaseClient || null;
  }

  function inPagesDir() {
    return window.location.pathname.includes('/pages/');
  }

  function pagePath(name) {
    return (inPagesDir() ? '' : 'pages/') + name;
  }

  function dashboardFor(role) {
    if (role === 'nurse') {
      return pagePath('nurse-dashboard.html');
    }

    if (role === 'admin') {
      return pagePath('admin-dashboard.html');
    }

    return pagePath('patient-dashboard.html');
  }

  function safeRedirectTarget(raw, fallback) {
    if (typeof raw !== 'string') return fallback;
    const clean = raw.trim();
    if (!clean) return fallback;

    // Prevent protocol or script injection
    if (/^\s*(javascript|vbscript|data\s*:)/i.test(clean)) return fallback;
    if (clean.includes('\\') || clean.startsWith('//') || clean.includes('\r') || clean.includes('\n')) return fallback;

    // If absolute URL, ensure it is strictly same-origin
    if (/^https?:\/\//i.test(clean)) {
      try {
        const url = new URL(clean, window.location.origin);
        if (url.origin !== window.location.origin) return fallback;
        const relative = url.pathname + url.search + url.hash;
        if (relative.includes('login.html') || relative.includes('register.html') || relative.includes('reset-password.html')) {
          return fallback;
        }
        return relative;
      } catch (_) {
        return fallback;
      }
    }

    // Allow relative paths within site
    if (clean.startsWith('/') || clean.endsWith('.html') || clean.includes('.html?') || clean.includes('.html#') || clean.startsWith('pages/')) {
      if (clean.includes('login.html') || clean.includes('register.html') || clean.includes('reset-password.html')) {
        return fallback;
      }
      return clean;
    }

    return fallback;
  }

  function sessionFallbackProfile(user) {
    const meta = user?.user_metadata || {};

    return {
      id: user.id,
      email: user.email || '',
      full_name:
        meta.full_name ||
        (user.email ? user.email.split('@')[0] : 'مستخدم'),
      phone: meta.phone || '',
      role: ['patient', 'nurse', 'admin'].includes(meta.role)
        ? meta.role
        : 'patient',
      avatar_url: meta.avatar_url || '',
      address: meta.address || '',
      governorate: meta.governorate || '',
      city: meta.city || '',
      country: meta.country || 'Egypt',
      _fallback: true,
    };
  }

  function friendlySignUpError(error) {
    const originalMessage = error?.message || '';
    let msg = originalMessage || 'فشل إنشاء الحساب';

    if (
      error?.code === 'email_provider_disabled' ||
      msg.includes('Email signups are disabled')
    ) {
      msg = 'التسجيل بالبريد الإلكتروني معطّل حالياً.';
    } else if (
      msg.includes('already registered') ||
      msg.includes('already exists') ||
      error?.code === 'user_already_exists'
    ) {
      msg = 'هذا البريد الإلكتروني مسجّل بالفعل. حاول تسجيل الدخول.';
    } else if (
      msg.includes('Password should') ||
      msg.includes('weak') ||
      error?.code === 'weak_password'
    ) {
      msg = `كلمة المرور يجب أن تحتوي على ${MIN_PASSWORD_LENGTH} أحرف على الأقل.`;
    } else if (
      msg.includes('Invalid email') ||
      error?.code === 'validation_failed'
    ) {
      msg = 'صيغة البريد الإلكتروني غير صحيحة.';
    } else if (error?.status === 429) {
      msg = 'طلبات كثيرة جداً. انتظر قليلاً ثم حاول مرة أخرى.';
    }

    const friendlyError = new Error(msg);
    friendlyError.originalError = error;
    friendlyError.code = error?.code;

    return friendlyError;
  }

  const Auth = {
    client() {
      return getClient();
    },

    safeRedirectTarget,
    dashboardFor,

    // ----------------------------------------------------------
    // قراءة جلسة المستخدم
    // ----------------------------------------------------------

    async getSession() {
      const sb = getClient();

      if (!sb) return null;

      try {
        const { data, error } = await sb.auth.getSession();

        if (error) {
          console.warn('تعذر قراءة الجلسة:', error.message);
          return null;
        }

        return data?.session || null;
      } catch (error) {
        console.warn(
          'خطأ أثناء قراءة الجلسة:',
          error?.message || error
        );
        return null;
      }
    },

    async getUser() {
      const session = await this.getSession();
      return session?.user || null;
    },

    // ----------------------------------------------------------
    // قراءة الملف الشخصي
    // ----------------------------------------------------------

    async getUserProfile() {
      const user = await this.getUser();
      const sb = getClient();

      if (!user || !sb) return null;

      try {
        const { data, error } = await sb
          .from('profiles')
          .select(
            'id,email,full_name,phone,role,avatar_url,address,country,governorate,city,created_at,updated_at'
          )
          .eq('id', user.id)
          .maybeSingle();

        if (error) {
          console.warn(
            'تعذر قراءة الملف الشخصي:',
            error.message
          );

          return sessionFallbackProfile(user);
        }

        if (!data) {
          console.warn(
            'لا يوجد سجل للمستخدم في profiles:',
            user.id
          );

          return sessionFallbackProfile(user);
        }

        return {
          ...data,
          email: data.email || user.email || '',
          full_name:
            data.full_name ||
            user.user_metadata?.full_name ||
            '',
          phone:
            data.phone ||
            user.user_metadata?.phone ||
            '',
          address:
            data.address ||
            user.user_metadata?.address ||
            '',
          governorate:
            data.governorate ||
            user.user_metadata?.governorate || '',
          city:
            data.city ||
            user.user_metadata?.city || '',
          country:
            data.country ||
            user.user_metadata?.country || 'Egypt',
          avatar_url: data.avatar_url || '',
        };
      } catch (error) {
        console.warn(
          'خطأ أثناء قراءة الملف الشخصي:',
          error?.message || error
        );

        return sessionFallbackProfile(user);
      }
    },

    // ----------------------------------------------------------
    // حفظ الرقم القومي عبر Edge Function
    // ----------------------------------------------------------

    async saveNationalId(nationalId) {
      const sb = getClient();

      if (!sb) {
        throw new Error('تعذر الاتصال بالخادم.');
      }

      const normalizedId = String(nationalId || '')
        .replace(/[٠-٩]/g, function (digit) {
          return String(digit.charCodeAt(0) - 0x0660);
        })
        .replace(/[۰-۹]/g, function (digit) {
          return String(digit.charCodeAt(0) - 0x06F0);
        })
        .replace(/[\s-]/g, '')
        .trim();

      if (!/^[0-9]{14}$/.test(normalizedId)) {
        throw new Error(
          'الرقم القومي يجب أن يتكون من 14 رقمًا.'
        );
      }

      const {
        data: sessionData,
        error: sessionError,
      } = await sb.auth.getSession();

      if (sessionError) {
        throw new Error('تعذر التحقق من جلسة المستخدم.');
      }

      const session = sessionData?.session;

      if (!session?.access_token) {
        throw new Error(
          'لا توجد جلسة دخول لحفظ الرقم القومي. سجّل الدخول أولاً.'
        );
      }

      const { data, error } = await sb.functions.invoke(
        NATIONAL_ID_FUNCTION,
        {
          body: {
            national_id: normalizedId,
            nationalId: normalizedId,
          },
        }
      );

      if (error) {
        console.error(
          'National ID function error:',
          error.message
        );

        throw new Error(
          data?.error || error.message || 'تعذر حفظ الرقم القومي. لم يتم تأكيد حفظه في قاعدة البيانات.'
        );
      }

      if (!data || data.success !== true) {
        throw new Error(
          data?.error || 'لم يتم تأكيد حفظ الرقم القومي.'
        );
      }

      return { success: true };
    },

    // ----------------------------------------------------------
    // إنشاء حساب
    // ----------------------------------------------------------

    async signUp({
      email,
      password,
      fullName,
      phone,
      role,
      governorate = '',
      city = '',
      address = '',
      nationalId = '',
    }) {
      const sb = getClient();

      if (!sb) {
        throw new Error('تعذر الاتصال بالخادم. حاول مرة أخرى.');
      }

      if (!email || !email.trim()) {
        throw new Error('يرجى إدخال البريد الإلكتروني.');
      }

      if (
        !password ||
        password.length < MIN_PASSWORD_LENGTH
      ) {
        throw new Error(
          `كلمة المرور يجب أن تحتوي على ${MIN_PASSWORD_LENGTH} أحرف على الأقل.`
        );
      }

      if (!/^(?=.*[a-zA-Z])(?=.*\d).{8,}$/.test(password)) {
        throw new Error(
          'يجب أن تحتوي كلمة المرور على أحرف وأرقام معاً لتعزيز أمان الحساب.'
        );
      }

      if (!fullName || fullName.trim().length < 3) {
        throw new Error(
          'يرجى إدخال الاسم الكامل بشكل صحيح.'
        );
      }

      const normalizedId = String(nationalId || '')
        .replace(/[٠-٩]/g, function (digit) {
          return String(digit.charCodeAt(0) - 0x0660);
        })
        .replace(/[۰-۹]/g, function (digit) {
          return String(digit.charCodeAt(0) - 0x06F0);
        })
        .replace(/[\s-]/g, '')
        .trim();

      if (!/^[0-9]{14}$/.test(normalizedId)) {
        throw new Error(
          'الرقم القومي يجب أن يتكون من 14 رقمًا.'
        );
      }

      const cleanRole =
        role === 'nurse' ? 'nurse' : 'patient';

      const { data, error } = await sb.auth.signUp({
        email: email.trim(),
        password,
        options: {
          data: {
            full_name: fullName.trim(),
            phone: phone ? phone.trim() : '',
            role: cleanRole,
            country: 'Egypt',
            governorate: governorate || '',
            city: city || '',
            address: address ? address.trim() : '',
          },
        },
      });

      if (error) {
        throw friendlySignUpError(error);
      }

      if (
        data?.user &&
        Array.isArray(data.user.identities) &&
        data.user.identities.length === 0
      ) {
        throw friendlySignUpError({
          code: 'user_already_exists',
          message: 'User already registered',
        });
      }

      if (!data?.user) {
        throw new Error('لم يتم تأكيد إنشاء الحساب.');
      }

      // If session exists immediately, update profiles row to guarantee address, governorate, and city are recorded
      if (data.session && data.user) {
        try {
          await sb.from('profiles').update({
            full_name: fullName.trim(),
            phone: phone ? phone.trim() : '',
            governorate: governorate || 'القاهرة',
            city: city || 'القاهرة',
            address: address ? address.trim() : '',
            country: 'Egypt'
          }).eq('id', data.user.id);
        } catch (updateErr) {
          console.warn('Post-signup profiles sync notice:', updateErr);
        }
      }

      let nationalIdSaved = false;
      let nationalIdSaveMessage = null;

      if (data.session) {
        try {
          await this.saveNationalId(normalizedId);
          nationalIdSaved = true;
        } catch (saveError) {
          nationalIdSaveMessage =
            saveError?.message ||
            'تعذر حفظ الرقم القومي.';
        }
      } else {
        nationalIdSaveMessage =
          'تم إنشاء الحساب، لكن حفظ الرقم القومي يحتاج إلى تسجيل الدخول بعد تأكيد البريد الإلكتروني.';
      }

      return {
        ...data,
        nationalIdSaved,
        nationalIdSaveMessage,
        needsEmailConfirmation: !data.session,
      };
    },

    // ----------------------------------------------------------
    // تسجيل الدخول
    // ----------------------------------------------------------

    async signIn({ email, password }) {
      const sb = getClient();

      if (!sb) {
        throw new Error('تعذر الاتصال بالخادم.');
      }

      if (!email || !email.trim() || !password) {
        throw new Error(
          'يرجى إدخال البريد الإلكتروني وكلمة المرور.'
        );
      }

      const { data, error } =
        await sb.auth.signInWithPassword({
          email: email.trim(),
          password,
        });

      if (error) {
        let message = error.message || 'فشل تسجيل الدخول';

        if (
          message.includes('Invalid login credentials') ||
          error.code === 'invalid_credentials'
        ) {
          message =
            'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
        } else if (
          message.includes('Email not confirmed')
        ) {
          message =
            'يرجى تأكيد بريدك الإلكتروني أولاً.';
        }

        const friendlyError = new Error(message);
        friendlyError.originalError = error;
        friendlyError.code = error.code;

        throw friendlyError;
      }

      return data;
    },

    // ----------------------------------------------------------
    // تسجيل الخروج
    // ----------------------------------------------------------

    async signOut() {
      const sb = getClient();

      if (!sb) return;

      try {
        const { error } = await sb.auth.signOut();

        if (error) {
          console.warn(
            'تعذر تسجيل الخروج:',
            error.message
          );
        }
      } catch (error) {
        console.warn(
          'خطأ أثناء تسجيل الخروج:',
          error?.message || error
        );
      }
    },

    // ----------------------------------------------------------
    // إعادة تعيين كلمة المرور
    // ----------------------------------------------------------

    async sendPasswordReset(email) {
      const sb = getClient();

      if (!sb) {
        throw new Error('تعذر الاتصال بالخادم.');
      }

      if (!email || !email.trim()) {
        throw new Error('يرجى إدخال البريد الإلكتروني.');
      }

      // استخدم siteUrl من الإعدادات إن وُجد (بيئة الإنتاج)
      // وإلا استخدم العنوان الحالي (التطوير المحلي)
      const cfg = (typeof CARENEST_CONFIG !== 'undefined' ? CARENEST_CONFIG : window.CARENEST_CONFIG) || {};
      const siteUrl = (cfg.app && cfg.app.siteUrl && cfg.app.siteUrl.trim()) || '';
      const baseUrl = siteUrl || window.location.origin;

      const { error } =
        await sb.auth.resetPasswordForEmail(
          email.trim(),
          {
            redirectTo: `${baseUrl}/pages/reset-password.html`,
          }
        );

      if (error) throw error;
    },

    // ----------------------------------------------------------
    // التحويل حسب دور المستخدم
    // ----------------------------------------------------------

    async redirectByRole() {
      const profile = await this.getUserProfile();

      if (!profile) {
        window.location.href = pagePath('login.html');
        return;
      }

      const target = dashboardFor(profile.role);

      if (!window.location.pathname.endsWith(target)) {
        window.location.href = target;
      }
    },

    // ----------------------------------------------------------
    // اشتراط تسجيل الدخول
    // ----------------------------------------------------------

    async requireAuth(allowedRoles = null) {
      const profile = await this.getUserProfile();

      if (!profile) {
        const redirect =
          window.location.pathname +
          window.location.search;

        window.location.href =
          `${pagePath('login.html')}?redirect=${encodeURIComponent(redirect)}`;

        return null;
      }

      if (
        allowedRoles &&
        !allowedRoles.includes(profile.role)
      ) {
        window.location.href =
          dashboardFor(profile.role);

        return null;
      }

      return profile;
    },
  };

  window.Auth = Auth;
})(typeof window !== 'undefined' ? window : this);