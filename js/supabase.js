// ============================================================
// رعايه | CareNest - Supabase Client & SDK Integration
// ============================================================

(function (window) {
  'use strict';

  let _supabase = null;

  function getConfig() {
    if (window.CARENEST_CONFIG) {
      return window.CARENEST_CONFIG;
    }

    if (typeof CARENEST_CONFIG !== 'undefined') {
      return CARENEST_CONFIG;
    }

    return null;
  }

  function getSupabase() {
    if (_supabase) return _supabase;

    const config = getConfig();

    if (
      !config ||
      !config.supabase ||
      !config.supabase.url ||
      config.supabase.url.includes('YOUR_')
    ) {
      console.error(
        '❌ رعايه: Supabase is not configured. Check js/config.js'
      );
      return null;
    }

    const createClientFn =
      window.supabase &&
        typeof window.supabase.createClient === 'function'
        ? window.supabase.createClient
        : window.Supabase &&
          typeof window.Supabase.createClient === 'function'
          ? window.Supabase.createClient
          : null;

    if (!createClientFn) {
      console.error(
        '❌ رعايه: Supabase SDK is not loaded.'
      );
      return null;
    }

    try {
      _supabase = createClientFn(
        config.supabase.url,
        config.supabase.anonKey,
        {
          auth: {
            autoRefreshToken: true,
            persistSession: true,
            detectSessionInUrl: true
          }
        }
      );

      window.supabaseClient = _supabase;

      console.log(
        '✅ رعايه: Supabase Client initialized successfully.'
      );

      return _supabase;
    } catch (error) {
      console.error(
        '❌ Error initializing Supabase client:',
        error
      );

      return null;
    }
  }

  // إزالة الحقول التي لا يُسمح بتعديلها من الواجهة.
  function omitKeys(obj, keys) {
    const output = { ...(obj || {}) };

    keys.forEach((key) => {
      delete output[key];
    });

    return output;
  }

  const AVATAR_EXT_BY_TYPE = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp'
  };

  // ============================================================
  // Database Utilities
  // ============================================================

  const DB = {
    client() {
      return getSupabase();
    },

    // DB.supabase: getter للتوافق مع الصفحات التي تستخدم DB.supabase.storage مباشرة
    get supabase() {
      return getSupabase();
    },

    // ==========================================================
    // Profiles
    // ==========================================================

    async updateProfile(userId, updates) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!userId) {
        throw new Error('معرّف المستخدم غير موجود.');
      }

      const cleanUpdates = {
        ...omitKeys(updates, [
          'id',
          'role',
          'email',
          'created_at',
          'national_id'
        ]),
        updated_at: new Date().toISOString()
      };

      const { data, error } = await sb
        .from('profiles')
        .update(cleanUpdates)
        .eq('id', userId)
        .select()
        .maybeSingle();

      if (error) {
        console.error('❌ updateProfile error:', error);
        throw error;
      }

      if (data) {
        return data;
      }

      throw new Error(
        'ملف المستخدم غير موجود في قاعدة البيانات. يجب إنشاء سجل profiles أولاً.'
      );
    },

    // ==========================================================
    // Nurse Profiles
    // ==========================================================

    async getNurseProfile(userId) {
      const sb = getSupabase();

      if (!sb || !userId) return null;

      try {
        const { data, error } = await sb
          .from('nurse_profiles')
          .select('*, profiles:user_id(*)')
          .eq('user_id', userId)
          .maybeSingle();

        if (error) {
          console.error('❌ getNurseProfile error:', error);
          throw error;
        }

        // نقل ومزامنة المحافظة والمدينة بين profiles و nurse_profiles إذا كانت ناقصة في أحدهما
        if (data) {
          const profGov = (data.profiles?.governorate || '').trim();
          const profCity = (data.profiles?.city || '').trim();
          const nurseGov = (data.governorate || '').trim();
          const nurseCity = (data.city || '').trim();

          if (!nurseGov && profGov) {
            try {
              await sb.from('nurse_profiles').update({
                governorate: profGov,
                city: nurseCity || profCity || null
              }).eq('user_id', userId);
              data.governorate = profGov;
              if (!data.city && profCity) data.city = profCity;
            } catch (syncErr) {
              console.warn('Sync nurse_profiles governorate notice:', syncErr);
            }
          } else if (nurseGov && !profGov) {
            try {
              await sb.from('profiles').update({
                governorate: nurseGov,
                city: profCity || nurseCity || null
              }).eq('id', userId);
              if (data.profiles) {
                data.profiles.governorate = nurseGov;
                if (!data.profiles.city && nurseCity) data.profiles.city = nurseCity;
              }
            } catch (syncErr) {
              console.warn('Sync profiles governorate notice:', syncErr);
            }
          }
        }

        return data;
      } catch (error) {
        console.warn(
          '⚠️ getNurseProfile exception:',
          error.message
        );

        return null;
      }
    },

    async setNurseAvailability(userId, isAvailable) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!userId) throw new Error('معرّف المستخدم غير موجود.');

      const available = Boolean(isAvailable);
      const { data, error } = await sb
        .from('nurse_profiles')
        .update({
          is_active: available,
          accepting_bookings: available
        })
        .eq('user_id', userId)
        .select()
        .single();

      if (error) {
        if (error.code === 'PGRST204' || (error.message && error.message.includes('column'))) {
          const retry = await sb
            .from('nurse_profiles')
            .update({ is_active: available })
            .eq('user_id', userId)
            .select()
            .single();
          if (retry.error) throw retry.error;
          return retry.data;
        }
        throw error;
      }
      return data;
    },

    async upsertNurseProfile(userId, updates) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!userId) {
        throw new Error('معرّف المستخدم غير موجود.');
      }

      let gov = updates.governorate ? String(updates.governorate).trim() : '';
      let city = updates.city ? String(updates.city).trim() : '';

      // إذا كانت المحافظة غير ممررة في التحديثات، استرجعها من profiles لضمان عدم بقاء nurse_profiles فارغة
      if (!gov) {
        try {
          const { data: prof } = await sb
            .from('profiles')
            .select('governorate, city')
            .eq('id', userId)
            .maybeSingle();
          if (prof?.governorate) {
            gov = prof.governorate.trim();
            if (!city && prof.city) city = prof.city.trim();
          }
        } catch (err) {
          console.warn('Could not read profiles for nurse_profiles backfill:', err);
        }
      }

      const payload = {
        ...omitKeys(updates, [
          'id',
          'user_id',
          'verified',
          'verification_status',
          'rejection_reason',
          'created_at'
        ]),
        user_id: userId
      };

      if (gov) payload.governorate = gov;
      if (city) payload.city = city;

      const { data, error } = await sb
        .from('nurse_profiles')
        .upsert(payload, {
          onConflict: 'user_id'
        })
        .select()
        .single();

      if (error) {
        console.error(
          '❌ upsertNurseProfile error:',
          error
        );

        throw error;
      }

      // إذا تم تحديد المحافظة والمدينة، نحدث جدول profiles كذلك لضمان تطابق الجدولين
      if (gov) {
        try {
          await sb.from('profiles').update({
            governorate: gov,
            city: city || null
          }).eq('id', userId);
        } catch (profErr) {
          console.warn('Sync to profiles table from nurse_profiles notice:', profErr);
        }
      }

      return data;
    },

    // ==========================================================
    // Avatar Management
    // ==========================================================

    async uploadAvatar(userId, file) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!userId) {
        throw new Error('معرّف المستخدم غير موجود.');
      }

      const config = getConfig();
      const appConfig = (config && config.app) || {};

      const allowedTypes =
        appConfig.allowedImageTypes ||
        Object.keys(AVATAR_EXT_BY_TYPE);

      const maxMB = appConfig.maxUploadSizeMB || 5;

      if (
        !file ||
        !allowedTypes.includes(file.type) ||
        !AVATAR_EXT_BY_TYPE[file.type]
      ) {
        throw new Error(
          'نوع الصورة غير مدعوم. استخدم JPG أو PNG أو WebP.'
        );
      }

      if (file.size > maxMB * 1024 * 1024) {
        throw new Error(
          `حجم الصورة كبير. الحد الأقصى ${maxMB} ميجابايت.`
        );
      }

      const filePath =
        `${userId}/avatar-${Date.now()}.` +
        AVATAR_EXT_BY_TYPE[file.type];

      const { error: uploadError } = await sb.storage
        .from('profile-photos')
        .upload(filePath, file, {
          cacheControl: '3600',
          contentType: file.type
        });

      if (uploadError) {
        console.error(
          '❌ Avatar upload error:',
          uploadError
        );

        const detail =
          uploadError.message || 'خطأ غير معروف';

        if (
          uploadError.statusCode === '401' ||
          uploadError.statusCode === '403'
        ) {
          throw new Error(
            'رفض Supabase رفع الصورة بسبب الصلاحيات. تحقق من تسجيل الدخول وسياسات Storage.'
          );
        }

        if (/bucket not found/i.test(detail)) {
          throw new Error(
            'مجلد تخزين الصور profile-photos غير موجود.'
          );
        }

        throw new Error(`فشل رفع الصورة: ${detail}`);
      }

      const { data: urlData } = sb.storage
        .from('profile-photos')
        .getPublicUrl(filePath);

      const publicUrl = urlData?.publicUrl;

      if (!publicUrl) {
        throw new Error('تعذّر الحصول على رابط الصورة.');
      }

      await this.updateProfile(userId, {
        avatar_url: publicUrl
      });

      return publicUrl;
    },

    async deleteAvatar(userId) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      const { data: profile, error: profileError } =
        await sb
          .from('profiles')
          .select('avatar_url')
          .eq('id', userId)
          .maybeSingle();

      if (profileError) {
        throw profileError;
      }

      const avatarUrl = profile?.avatar_url;

      if (avatarUrl) {
        const marker =
          '/storage/v1/object/public/profile-photos/';

        const markerIndex = avatarUrl.indexOf(marker);

        if (markerIndex >= 0) {
          const objectPath = decodeURIComponent(
            avatarUrl.slice(markerIndex + marker.length)
          );

          if (
            objectPath.startsWith(`${userId}/`) &&
            !objectPath.includes('..')
          ) {
            const { error: removeError } = await sb.storage
              .from('profile-photos')
              .remove([objectPath]);

            if (removeError) {
              throw removeError;
            }
          }
        }
      }

      await this.updateProfile(userId, {
        avatar_url: null
      });

      return true;
    },

    // ==========================================================
    // Services Catalog
    // ==========================================================

    async getServices() {
      let sb = getSupabase();

      if (!sb) {
        for (let i = 0; i < 5; i++) {
          await new Promise((resolve) =>
            setTimeout(resolve, 200)
          );

          sb = getSupabase();

          if (sb) break;
        }
      }

      if (!sb) {
        throw new Error(
          'تعذّر الاتصال بقاعدة البيانات. راجع إعدادات js/config.js.'
        );
      }

      const { data, error } = await sb
        .from('services')
        .select('*')
        .eq('is_active', true)
        .in('provider_type', ['nurse', 'both'])
        .order('base_price', {
          ascending: true
        });

      if (error) {
        console.error(
          '❌ getServices error:',
          error
        );

        throw new Error(
          `تعذّر جلب الخدمات: ${error.message}`
        );
      }

      return data || [];
    },

    // ==========================================================
    // Verified Nurses
    // ==========================================================

    async getVerifiedNurses(filters = {}) {
      let sb = getSupabase();

      if (!sb) {
        for (let i = 0; i < 5; i++) {
          await new Promise((resolve) =>
            setTimeout(resolve, 200)
          );

          sb = getSupabase();

          if (sb) break;
        }
      }

      if (!sb) {
        throw new Error(
          'تعذّر الاتصال بقاعدة البيانات.'
        );
      }

      let query = sb
        .from('public_nurses')
        .select('*')
        .eq('verified', true)
        .order('created_at', {
          ascending: false
        });

      if (filters.governorate) {
        query = query.eq(
          'governorate',
          filters.governorate
        );
      }

      if (filters.city) {
        query = query.eq('city', filters.city);
      }

      if (filters.specialty) {
        query = query.ilike(
          'specialization',
          `%${filters.specialty}%`
        );
      }

      if (filters.maxPrice) {
        query = query.lte(
          'visit_price',
          Number(filters.maxPrice)
        );
      }

      if (filters.limit) {
        query = query.limit(Number(filters.limit));
      }

      const { data, error } = await query;

      if (error) {
        console.error(
          '❌ getVerifiedNurses error:',
          error
        );

        throw new Error(
          `خطأ في استعلام الممرضين: ${error.message}`
        );
      }

      let nurses = (data || [])
        .filter(
          (nurse) =>
            nurse.verified === true &&
            nurse.is_active !== false
        )
        .map((nurse) => ({
          ...nurse,
          profiles: {
            id: nurse.user_id,
            full_name: nurse.full_name,
            avatar_url: nurse.avatar_url
          }
        }));

      if (filters.search) {
        const searchText =
          filters.search.toLowerCase().trim();

        nurses = nurses.filter((nurse) =>
          (nurse.full_name || '')
            .toLowerCase()
            .includes(searchText) ||
          (nurse.specialization || '')
            .toLowerCase()
            .includes(searchText) ||
          (nurse.governorate || '')
            .toLowerCase()
            .includes(searchText) ||
          (nurse.city || '')
            .toLowerCase()
            .includes(searchText)
        );
      }

      return nurses;
    },

    // ==========================================================
    // Physiotherapists Directory (دليل أخصائيي العلاج الطبيعي)
    // يستعلم أخصائيي العلاج الطبيعي المعتمدين والنشطين فقط
    // ==========================================================

    async getVerifiedPhysiotherapists(filters = {}) {
      let sb = getSupabase();
      if (!sb) {
        for (let i = 0; i < 5; i++) {
          await new Promise((resolve) => setTimeout(resolve, 200));
          sb = getSupabase();
          if (sb) break;
        }
      }
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      let query = sb
        .from('physiotherapist_profiles')
        .select('*')
        .eq('verified', true)
        .eq('is_active', true)
        .eq('accepting_bookings', true)
        .order('created_at', { ascending: false });

      if (filters.governorate) {
        query = query.eq('governorate', filters.governorate);
      }

      const { data: pProfiles, error } = await query;
      if (error) {
        console.error('❌ getVerifiedPhysiotherapists error:', error);
        throw new Error(`خطأ في استعلام أخصائيي العلاج الطبيعي: ${error.message}`);
      }

      let physios = (pProfiles || []).filter((p) => {
        const vStatus = p.verification_status || (p.verified ? 'approved' : 'pending');
        return vStatus === 'approved' && p.is_active === true && p.accepting_bookings === true;
      });

      const userIds = [...new Set(physios.map((p) => p.user_id).filter(Boolean))];
      const profileMap = {};

      if (userIds.length > 0) {
        try {
          const { data: pList, error: pErr } = await sb
            .from('profiles')
            .select('id, full_name, email, phone, avatar_url, governorate, city')
            .in('id', userIds);

          if (!pErr && pList) {
            pList.forEach((p) => { profileMap[p.id] = p; });
          }
        } catch (fetchErr) {
          console.warn('⚠️ getVerifiedPhysiotherapists profiles lookup warning:', fetchErr);
        }
      }

      physios = physios.map((ph) => {
        const p = profileMap[ph.user_id] || {};
        return {
          id: ph.id,
          user_id: ph.user_id,
          full_name: p.full_name || 'أخصائي علاج طبيعي معتمد',
          avatar_url: p.avatar_url || null,
          phone: p.phone || '',
          specialization: ph.specialization || 'العلاج الطبيعي والتأهيل',
          experience_years: ph.experience_years || 0,
          qualifications: ph.qualifications || '',
          bio: ph.bio || '',
          session_price: Number(ph.session_price || 200),
          governorate: ph.governorate || p.governorate || '—',
          city: ph.city || p.city || '—',
          verified: true,
          is_active: true,
          accepting_bookings: true
        };
      });

      if (filters.search) {
        const searchText = filters.search.toLowerCase().trim();
        physios = physios.filter((ph) =>
          (ph.full_name || '').toLowerCase().includes(searchText) ||
          (ph.specialization || '').toLowerCase().includes(searchText) ||
          (ph.governorate || '').toLowerCase().includes(searchText) ||
          (ph.city || '').toLowerCase().includes(searchText)
        );
      }

      return physios;
    },

    // ==========================================================
    // Bookings
    // العلاقة المعتمدة: bookings.nurse_id -> profiles.id و bookings.nurse_profile_id -> nurse_profiles.id
    // ==========================================================

    async createBooking(bookingData) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!bookingData) {
        throw new Error('بيانات الحجز غير موجودة.');
      }

      const {
        data: { session },
        error: sessionError
      } = await sb.auth.getSession();

      if (sessionError) {
        throw sessionError;
      }

      const user = session?.user;

      if (!user) {
        throw new Error(
          'يجب تسجيل الدخول أولاً لإتمام الحجز.'
        );
      }

      // معرّف الممرض المستهدف: nurse_profiles.id حصراً كما هو مؤكد في مخطط قاعدة البيانات
      const nurseId =
        bookingData.nurse_id ||
        bookingData.nurse_profile_id;

      if (!nurseId) {
        throw new Error(
          'يرجى اختيار ممرض لإتمام الحجز.'
        );
      }

      // يجب أن يكون اسم الخدمة العربي الموجود في services.name_ar
      const serviceType =
        bookingData.service_type ||
        bookingData.service_name;

      if (!serviceType) {
        throw new Error(
          'يرجى اختيار الخدمة المطلوبة.'
        );
      }

      const visitDate = bookingData.visit_date;

      const startTime =
        bookingData.start_time ||
        bookingData.visit_time;

      if (!visitDate || !startTime) {
        throw new Error(
          'يرجى تحديد تاريخ ووقت الزيارة.'
        );
      }

      // ==========================================================
      // حساب مدة الزيارة بالدقائق ووقت الانتهاء (end_time)
      // ==========================================================
      let durationMinutes = 0;

      // أ) محاولة أخذ مدة الخدمة بالدقائق من بيانات الحجز المباشرة
      if (
        bookingData.duration_minutes != null &&
        Number.isFinite(Number(bookingData.duration_minutes)) &&
        Number(bookingData.duration_minutes) > 0
      ) {
        durationMinutes = Math.round(Number(bookingData.duration_minutes));
      } else if (
        bookingData.duration != null &&
        Number.isFinite(Number(bookingData.duration)) &&
        Number(bookingData.duration) > 0
      ) {
        durationMinutes = Math.round(Number(bookingData.duration));
      }

      // ب) إذا لم تتوفر في بيانات الحجز، جلب مدة الخدمة الصحيحة بالدقائق من جدول services
      if (!durationMinutes && (bookingData.service_id || serviceType)) {
        try {
          let sQuery = sb.from('services').select('duration_minutes');
          if (bookingData.service_id) {
            sQuery = sQuery.eq('id', bookingData.service_id);
          } else {
            sQuery = sQuery.eq('name_ar', serviceType);
          }
          const { data: sData } = await sQuery.maybeSingle();
          if (sData?.duration_minutes && Number(sData.duration_minutes) > 0) {
            durationMinutes = Math.round(Number(sData.duration_minutes));
          }
        } catch (_) {}
      }

      // جـ) بديل: إذا تم تمرير مدة في duration_hours
      if (!durationMinutes && bookingData.duration_hours != null) {
        const rawHours = Number(bookingData.duration_hours);
        if (Number.isFinite(rawHours) && rawHours > 0) {
          // إذا كانت القيمة أكبر من 12 فهي ممررة بالدقائق (مثل 30 أو 45 أو 60 دقيقة)
          durationMinutes = rawHours > 12 ? Math.round(rawHours) : Math.round(rawHours * 60);
        }
      }

      // د) التحقق من أن مدة الزيارة صالحة وأكبر من الصفر
      if (!Number.isFinite(durationMinutes) || durationMinutes <= 0) {
        throw new Error('مدة الزيارة غير صحيحة أو غير محددة.');
      }

      // هـ) تحليل وقت البداية وتحويله إلى دقائق منذ منتصف الليل
      const timeParts = startTime.split(':').map(Number);
      const [hours, minutes, seconds = 0] = timeParts;

      if (
        timeParts.length < 2 ||
        timeParts.length > 3 ||
        !Number.isInteger(hours) ||
        hours < 0 ||
        hours > 23 ||
        !Number.isInteger(minutes) ||
        minutes < 0 ||
        minutes > 59 ||
        !Number.isInteger(seconds) ||
        seconds < 0 ||
        seconds > 59
      ) {
        throw new Error('وقت الزيارة غير صحيح.');
      }

      const startTotalMinutes = hours * 60 + minutes;
      const endTotalMinutes = startTotalMinutes + durationMinutes;

      // و) رفض الحجز إذا تجاوز وقت الانتهاء 23:59 (1439 دقيقة) دون تغيير التاريخ تلقائياً
      if (endTotalMinutes > 1439) {
        throw new Error('وقت انتهاء الزيارة يتجاوز نهاية اليوم. يرجى اختيار موعد أبكر.');
      }

      const pad = (number) => String(number).padStart(2, '0');
      const endHours = Math.floor(endTotalMinutes / 60);
      const endMins = endTotalMinutes % 60;

      const endTime = [
        pad(endHours),
        pad(endMins),
        '00'
      ].join(':');

      const submittedPrice = Number(
        bookingData.price ??
        bookingData.total_price ??
        0
      );

      if (
        !Number.isFinite(submittedPrice) ||
        submittedPrice < 0
      ) {
        throw new Error(
          'سعر الحجز غير صحيح.'
        );
      }

      // ==========================================================
      // التحقق الصارم من المحافظة من قاعدة البيانات (Backend Check)
      // منع الحجز بين محافظات مختلفة والتحقق من حساب المريض والممرض
      // ==========================================================
      // 1. استعلام المحافظة المسجلة فعلياً في حساب المريض
      const { data: patientProfile, error: pErr } = await sb
        .from('profiles')
        .select('id, governorate')
        .eq('id', user.id)
        .maybeSingle();

      if (pErr) {
        console.error('Failed to fetch patient profile:', pErr);
        throw new Error('تعذر التحقق من بيانات الملف الشخصي للمريض.');
      }

      const patientGov = (patientProfile?.governorate || '').trim();
      if (!patientGov) {
        throw new Error(
          'لم يتم تسجيل المحافظة في ملفك الشخصي. يرجى استكمال بيانات المحافظة في ملفك الشخصي أولاً لإتمام الحجز.'
        );
      }

      // 2. استعلام المحافظة المسجلة فعلياً للممرض
      let nurseGov = '';
      let nurseCity = '';
      let targetUserId = bookingData.nurse_user_id || null;

      // أ) محاولة الاستعلام من nurse_profiles
      const { data: nurseProfile } = await sb
        .from('nurse_profiles')
        .select('id, user_id, governorate, city')
        .or(`id.eq.${nurseId},user_id.eq.${nurseId}`)
        .maybeSingle();

      if (nurseProfile) {
        nurseGov = (nurseProfile.governorate || '').trim();
        nurseCity = (nurseProfile.city || '').trim();
        if (nurseProfile.user_id) targetUserId = nurseProfile.user_id;
      }

      // ب) إذا لم يُرجع جدول nurse_profiles نتيجة للمريض بسبب RLS، نستعلم من public_nurses المخصصة للجمهور
      if (!nurseGov) {
        const { data: pubNurse } = await sb
          .from('public_nurses')
          .select('id, user_id, governorate, city')
          .or(`id.eq.${nurseId},user_id.eq.${nurseId}`)
          .maybeSingle();

        if (pubNurse) {
          nurseGov = (pubNurse.governorate || '').trim();
          nurseCity = (pubNurse.city || '').trim();
          if (pubNurse.user_id) targetUserId = pubNurse.user_id;
        }
      }

      // جـ) إذا لم نصل للمحافظة بعد، نحاول من profiles إذا كان معرّف المستخدم متوفراً
      if (!nurseGov && targetUserId) {
        const { data: nurseUserProfile } = await sb
          .from('profiles')
          .select('governorate, city')
          .eq('id', targetUserId)
          .maybeSingle();

        if (nurseUserProfile?.governorate) {
          nurseGov = nurseUserProfile.governorate.trim();
          nurseCity = (nurseUserProfile.city || '').trim();
        }
      }

      // نقل المحافظة إلى nurse_profiles تلقائياً إذا كانت موجودة في profiles أو public_nurses
      if (nurseGov && nurseProfile?.id && !nurseProfile.governorate) {
        try {
          await sb.from('nurse_profiles').update({
            governorate: nurseGov,
            city: nurseCity || null
          }).eq('id', nurseProfile.id);
        } catch (_) {}
      }

      // د) اعتماد المحافظة والمدينة الممررة في بيانات الحجز إن توفرت
      if (!nurseGov && bookingData.nurse_governorate) {
        nurseGov = (bookingData.nurse_governorate || '').trim();
      }
      if (!nurseCity && bookingData.nurse_city) {
        nurseCity = (bookingData.nurse_city || '').trim();
      }

      if (!nurseGov) {
        throw new Error('بيانات الممرض غير مكتملة: لم يتم تسجيل محافظة الممرض في النظام. يرجى من الممرض استكمال المحافظة والمدينة في ملفه الشخصي قبل استقبال الحجوزات.');
      }

      // 3. التحقق الصارم من تطابق محافظة المريض مع محافظة الممرض
      if (patientGov !== nurseGov) {
        throw new Error(
          `لا يمكن إتمام الحجز: الممرض مسجل في محافظة (${nurseGov}) بينما محافظتك المسجلة هي (${patientGov}). يُشترط أن يكون الممرض من نفس المحافظة.`
        );
      }

      // فحص تعارض المواعيد للممرض لنفس التاريخ للحالات النشطة
      const { data: conflicts, error: conflictError } = await sb
        .from('bookings')
        .select('id, start_time, end_time, status')
        .eq('nurse_id', nurseId)
        .eq('visit_date', visitDate)
        .in('status', ['pending', 'accepted', 'in_progress']);

      if (conflictError) {
        console.error('Booking conflict check failed:', conflictError);
        throw new Error(
          'تعذر التحقق من مواعيد الممرض. حاول مرة أخرى.'
        );
      }

      // تحويل الوقت إلى دقائق لتجنب المقارنة النصية
      const toMinutes = (time) => {
        if (!time || typeof time !== 'string') {
          return null;
        }

        const parts = time.split(':').map(Number);
        const [h, m, s = 0] = parts;

        if (
          parts.length < 2 ||
          parts.length > 3 ||
          !Number.isInteger(h) ||
          h < 0 || h > 23 ||
          !Number.isInteger(m) ||
          m < 0 || m > 59 ||
          !Number.isInteger(s) ||
          s < 0 || s > 59
        ) {
          return null;
        }

        return h * 60 + m + s / 60;
      };

      const newStart = toMinutes(startTime);
      const newEnd = toMinutes(endTime);

      if (newStart === null || newEnd === null || newEnd <= newStart) {
        throw new Error('وقت الزيارة غير صحيح.');
      }

      const hasConflict = (conflicts || []).some((booking) => {
        if (bookingData.id && booking.id === bookingData.id) {
          return false;
        }

        const existingStart = toMinutes(booking.start_time);

        // حجز نشط بلا وقت انتهاء أو وقت بداية غير سليم: نمنع الحجز احتياطيًا
        if (existingStart === null || !booking.end_time) {
          return true;
        }

        const existingEnd = toMinutes(booking.end_time);

        // بيانات وقت غير سليمة: نمنع الحجز احتياطيًا
        if (existingEnd === null || existingEnd <= existingStart) {
          return true;
        }

        // فحص التداخل بنظام [start, end)
        return newStart < existingEnd && newEnd > existingStart;
      });

      if (hasConflict) {
        throw new Error(
          'هذا الممرض لديه حجز آخر في هذا الموعد، يرجى اختيار موعد مختلف أو ممرض آخر.'
        );
      }

      // تجهيز عنوان المريض مع تضمين إحداثيات GPS إن توفرت
      const rawAddress = (bookingData.patient_address || '').trim();
      const hasCoords = bookingData.latitude != null && bookingData.longitude != null &&
        !isNaN(Number(bookingData.latitude)) && !isNaN(Number(bookingData.longitude));

      const formattedAddress = hasCoords && !rawAddress.includes('[GPS:')
        ? `${rawAddress} [GPS: ${Number(bookingData.latitude).toFixed(6)}, ${Number(bookingData.longitude).toFixed(6)}]`
        : rawAddress;

      // الأعمدة الفعلية الموجودة في جدول bookings حصراً (دون إرسال أعمدة غير موجودة)
      const payload = {
        patient_id: user.id,
        nurse_id: nurseId,
        service_type: serviceType,
        visit_date: visitDate,
        start_time: startTime,
        end_time: endTime,
        governorate: patientGov,
        patient_address: formattedAddress,
        patient_notes:
          bookingData.patient_notes ||
          bookingData.notes ||
          null,
        price: submittedPrice,
        status: 'pending',
        payment_method: ['cash', 'vodafone_cash', 'instapay'].includes(bookingData.payment_method) ? bookingData.payment_method : 'cash',
        payment_status: (bookingData.payment_method === 'vodafone_cash' || bookingData.payment_method === 'instapay') ? 'pending_review' : 'pending',
        payment_receipt_path: bookingData.payment_receipt_path || null
      };

      const {
        data,
        error
      } = await sb
        .from('bookings')
        .insert(payload)
        .select()
        .single();

      if (error) {
        console.error(
          '❌ createBooking error:',
          {
            message: error.message,
            code: error.code,
            details: error.details,
            hint: error.hint
          }
        );

        throw error;
      }

      return data;
    },

    // ==========================================================
    // Physiotherapist Booking
    // ==========================================================

    async createPhysiotherapistBooking(bookingData) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!bookingData) {
        throw new Error('بيانات الحجز غير موجودة.');
      }

      const {
        data: { session },
        error: sessionError
      } = await sb.auth.getSession();

      if (sessionError) {
        throw sessionError;
      }

      const user = session?.user;

      if (!user) {
        throw new Error('يجب تسجيل الدخول أولاً لإتمام الحجز.');
      }

      const physioId = bookingData.physio_id || bookingData.physiotherapist_profile_id;

      if (!physioId) {
        throw new Error('يرجى اختيار أخصائي علاج طبيعي لإتمام الحجز.');
      }

      const serviceType = bookingData.service_type || bookingData.service_name || 'جلسة علاج طبيعي وتأهيل منزلي';
      const visitDate = bookingData.visit_date;
      const startTime = bookingData.start_time || bookingData.visit_time;

      if (!visitDate || !startTime) {
        throw new Error('يرجى تحديد تاريخ ووقت الزيارة.');
      }

      const submittedDurationHours = Number(bookingData.duration_hours || 1);
      if (!Number.isFinite(submittedDurationHours) || submittedDurationHours <= 0) {
        throw new Error('يرجى تحديد مدة الجلسة بالساعات لإتمام الحجز.');
      }
      const durationHours = submittedDurationHours;
      const durationMinutes = Math.round(durationHours * 60);

      const timeParts = startTime.split(':').map(Number);
      const [hours, minutes, seconds = 0] = timeParts;

      if (
        timeParts.length < 2 ||
        timeParts.length > 3 ||
        !Number.isInteger(hours) ||
        hours < 0 || hours > 23 ||
        !Number.isInteger(minutes) ||
        minutes < 0 || minutes > 59 ||
        !Number.isInteger(seconds) ||
        seconds < 0 || seconds > 59
      ) {
        throw new Error('وقت الزيارة غير صحيح.');
      }

      const startTotalMinutes = hours * 60 + minutes;
      const endTotalMinutes = startTotalMinutes + durationMinutes;

      if (endTotalMinutes > 1440) {
        throw new Error('وقت انتهاء الزيارة يتجاوز نهاية اليوم (12:00 منتصف الليل). يرجى اختيار موعد أبكر.');
      }

      const pad = (number) => String(number).padStart(2, '0');
      const endTime = [
        pad(Math.floor((endTotalMinutes % 1440) / 60)),
        pad((endTotalMinutes % 1440) % 60),
        '00'
      ].join(':');

      // جلب بيانات المريض من profiles
      const { data: patientProfile, error: pErr } = await sb
        .from('profiles')
        .select('id, full_name, phone, address, governorate, city')
        .eq('id', user.id)
        .maybeSingle();

      if (pErr) {
        console.error('Failed to fetch patient profile:', pErr);
        throw new Error('تعذر التحقق من بيانات الملف الشخصي للمريض.');
      }

      const patientGov = (patientProfile?.governorate || '').trim();

      // جلب بيانات أخصائي العلاج الطبيعي (التحقق بمعرف الملف المهني أو معرف المستخدم)
      const { data: physioProfile, error: phErr } = await sb
        .from('physiotherapist_profiles')
        .select('id, user_id, session_price, governorate, city, verified, is_active, accepting_bookings')
        .or(`id.eq.${physioId},user_id.eq.${physioId}`)
        .maybeSingle();

      if (phErr || !physioProfile) {
        console.error('Failed to fetch physio profile:', phErr);
        throw new Error('تعذر التحقق من بيانات أخصائي العلاج الطبيعي.');
      }

      let physioGov = (physioProfile?.governorate || '').trim();
      let physioCity = (physioProfile?.city || '').trim();
      if (!physioGov && physioProfile?.user_id) {
        const { data: physioUserProfile } = await sb
          .from('profiles')
          .select('governorate, city')
          .eq('id', physioProfile.user_id)
          .maybeSingle();
        physioGov = (physioUserProfile?.governorate || '').trim();
        if (!physioCity) physioCity = (physioUserProfile?.city || '').trim();
      }

      if (patientGov && physioGov && patientGov !== physioGov) {
        throw new Error(
          `لا يمكن إتمام الحجز: الأخصائي مسجل في محافظة (${physioGov}) بينما محافظتك المسجلة هي (${patientGov}). يُشترط أن يكون الأخصائي من نفس المحافظة.`
        );
      }

      const submittedPrice = Number(
        bookingData.price ??
        bookingData.total_price ??
        physioProfile.session_price ??
        200
      );

      // فحص تعارض المواعيد للأخصائي لنفس التاريخ باستخدام معرف الملف المهني المعتمد
      const finalPhysioId = physioProfile.id;

      const { data: conflicts, error: conflictError } = await sb
        .from('bookings')
        .select('id, start_time, end_time, status')
        .eq('physio_id', finalPhysioId)
        .eq('visit_date', visitDate)
        .in('status', ['pending', 'accepted', 'in_progress']);

      if (conflictError) {
        console.error('Physio booking conflict check failed:', conflictError);
        throw new Error('تعذر التحقق من مواعيد الأخصائي. حاول مرة أخرى.');
      }

      const toMinutes = (time) => {
        if (!time || typeof time !== 'string') return null;
        const parts = time.split(':').map(Number);
        const [h, m, s = 0] = parts;
        if (parts.length < 2 || parts.length > 3 || !Number.isInteger(h) || h < 0 || h > 23 || !Number.isInteger(m) || m < 0 || m > 59) return null;
        return h * 60 + m + (s || 0) / 60;
      };

      const newStart = toMinutes(startTime);
      const newEnd = toMinutes(endTime);

      const hasConflict = (conflicts || []).some((b) => {
        if (bookingData.id && b.id === bookingData.id) return false;
        const exStart = toMinutes(b.start_time);
        if (exStart === null || !b.end_time) return true;
        const exEnd = toMinutes(b.end_time);
        if (exEnd === null || exEnd <= exStart) return true;
        return newStart < exEnd && newEnd > exStart;
      });

      if (hasConflict) {
        throw new Error('هذا الأخصائي لديه موعد آخر في هذا التوقيت، يرجى اختيار موعد مختلف.');
      }

      const rawAddress = (bookingData.patient_address || patientProfile?.address || '').trim();
      if (!rawAddress) {
        throw new Error('يرجى تحديد عنوان الزيارة لإتمام الحجز.');
      }

      const hasCoords = bookingData.latitude != null && bookingData.longitude != null &&
        !isNaN(Number(bookingData.latitude)) && !isNaN(Number(bookingData.longitude));

      const formattedAddress = hasCoords && !rawAddress.includes('[GPS:')
        ? `${rawAddress} [GPS: ${Number(bookingData.latitude).toFixed(6)}, ${Number(bookingData.longitude).toFixed(6)}]`
        : rawAddress;

      // الأعمدة الفعلية الموجودة حصراً في جدول bookings بقاعدة البيانات
      const payload = {
        patient_id: user.id,
        nurse_id: null,
        physio_id: finalPhysioId,
        provider_type: 'physiotherapist',
        service_type: serviceType,
        visit_date: visitDate,
        start_time: startTime,
        end_time: endTime,
        price: submittedPrice,
        governorate: patientGov || physioGov || 'القاهرة',
        city: (patientProfile?.city || physioCity || 'القاهرة').trim(),
        patient_address: formattedAddress,
        patient_notes: bookingData.patient_notes || bookingData.notes || null,
        status: 'pending',
        payment_method: ['cash', 'vodafone_cash', 'instapay'].includes(bookingData.payment_method) ? bookingData.payment_method : 'cash',
        payment_status: (bookingData.payment_method === 'vodafone_cash' || bookingData.payment_method === 'instapay') ? 'pending_review' : 'pending',
        payment_receipt_path: bookingData.payment_receipt_path || null
      };

      // طباعة الـ Payload قبل الإدراج دون بيانات شخصية حساسة
      console.log('📦 [createPhysiotherapistBooking] Payload before INSERT:', {
        patient_id: payload.patient_id,
        nurse_id: payload.nurse_id,
        physio_id: payload.physio_id,
        provider_type: payload.provider_type,
        service_type: payload.service_type,
        visit_date: payload.visit_date,
        start_time: payload.start_time,
        end_time: payload.end_time,
        price: payload.price,
        governorate: payload.governorate,
        city: payload.city,
        has_address: Boolean(payload.patient_address),
        has_notes: Boolean(payload.patient_notes),
        status: payload.status,
        payment_method: payload.payment_method,
        payment_status: payload.payment_status,
        has_receipt: Boolean(payload.payment_receipt_path)
      });

      const { data, error } = await sb
        .from('bookings')
        .insert(payload)
        .select()
        .single();

      if (error) {
        console.error('❌ createPhysiotherapistBooking error details:', {
          message: error.message,
          details: error.details,
          hint: error.hint,
          code: error.code
        });
        const fullMsg = `[${error.code || 'DB_ERROR'}]: ${error.message || 'خطأ في حفظ الحجز'}${error.details ? ' | ' + error.details : ''}${error.hint ? ' (' + error.hint + ')' : ''}`;
        const err = new Error(fullMsg);
        err.code = error.code;
        err.details = error.details;
        err.hint = error.hint;
        throw err;
      }

      return data;
    },

    // ==========================================================
    // Patient Bookings
    // ==========================================================

    async getPatientBookings(patientId, status = null) {
      const sb = getSupabase();

      if (!sb) return [];

      if (!patientId) {
        throw new Error('معرّف المريض غير موجود.');
      }

      // 1. استعلام جدول bookings مباشرة باستخدام الحقول الحقيقية
      let query = sb
        .from('bookings')
        .select('*')
        .eq('patient_id', patientId)
        .order('created_at', { ascending: false });

      if (status && status !== 'all') {
        query = query.eq('status', status);
      }

      const { data, error } = await query;

      if (error) {
        console.error('❌ getPatientBookings error:', error);
        throw new Error(`فشل جلب حجوزات المريض: ${error.message || error.code}`);
      }

      const rawBookings = data || [];

      // 2. جلب بيانات الممرضين المرتبطين بالحجوزات (بدقة عبر profiles.id و nurse_profiles.id)
      const nurseUserIds = [...new Set(rawBookings.map(b => b.nurse_id).filter(Boolean))];
      const nurseProfileIds = [...new Set(rawBookings.map(b => b.nurse_profile_id).filter(Boolean))];
      const allPossibleNurseIds = [...new Set([...nurseUserIds, ...nurseProfileIds])];
      const nurseMap = {};

      if (allPossibleNurseIds.length > 0) {
        try {
          // استعلام nurse_profiles بمعرف الحساب أو معرف الملف المهني
          const idListStr = allPossibleNurseIds.map(id => `"${id}"`).join(',');
          const { data: nProfiles, error: npError } = await sb
            .from('nurse_profiles')
            .select('id, user_id, specialization, governorate, city')
            .or(`id.in.(${idListStr}),user_id.in.(${idListStr})`);

          if (!npError && nProfiles) {
            const userIds = [...new Set(nProfiles.map(np => np.user_id).concat(nurseUserIds).filter(Boolean))];
            let userProfilesMap = {};

            if (userIds.length > 0) {
              const { data: uProfiles } = await sb
                .from('profiles')
                .select('id, full_name, phone, avatar_url')
                .in('id', userIds);

              if (uProfiles) {
                uProfiles.forEach(u => { userProfilesMap[u.id] = u; });
              }
            }

            nProfiles.forEach(np => {
              const u = userProfilesMap[np.user_id] || {};
              const record = {
                id: np.id,
                user_id: np.user_id,
                full_name: u.full_name || 'ممرض معتمد',
                phone: u.phone || '',
                avatar_url: u.avatar_url || null,
                specialization: np.specialization || ''
              };
              nurseMap[np.id] = record;
              nurseMap[np.user_id] = record;
            });
          }

          // فحص احتياطي لأي حجز مباشر
          const missingNurseIds = allPossibleNurseIds.filter(id => !nurseMap[id]);
          if (missingNurseIds.length > 0) {
            const { data: directProfiles } = await sb
              .from('profiles')
              .select('id, full_name, phone, avatar_url')
              .in('id', missingNurseIds);

            if (directProfiles) {
              directProfiles.forEach(p => {
                const record = {
                  id: p.id,
                  user_id: p.id,
                  full_name: p.full_name || 'ممرض معتمد',
                  phone: p.phone || '',
                  avatar_url: p.avatar_url || null,
                  specialization: ''
                };
                nurseMap[p.id] = record;
              });
            }
          }
        } catch (nErr) {
          console.warn('⚠️ تعذّر استرجاع تفاصيل الممرض للحجز:', nErr);
        }
      }

      // 3. جلب بيانات أخصائيي العلاج الطبيعي المرتبطين بالحجوزات
      const physioProfileIds = [...new Set(rawBookings.map(b => b.physio_id).filter(Boolean))];
      const physioMap = {};

      if (physioProfileIds.length > 0) {
        try {
          const { data: pProfiles, error: ppError } = await sb
            .from('physiotherapist_profiles')
            .select('id, user_id, specialization, governorate, city')
            .in('id', physioProfileIds);

          if (!ppError && pProfiles) {
            const userIds = [...new Set(pProfiles.map(p => p.user_id).filter(Boolean))];
            let userProfilesMap = {};

            if (userIds.length > 0) {
              const { data: uProfiles } = await sb
                .from('profiles')
                .select('id, full_name, phone, avatar_url')
                .in('id', userIds);

              if (uProfiles) {
                uProfiles.forEach(u => { userProfilesMap[u.id] = u; });
              }
            }

            pProfiles.forEach(p => {
              const u = userProfilesMap[p.user_id] || {};
              const rawName = (u.full_name || 'أخصائي علاج طبيعي معتمد').trim();
              const displayName = rawName.startsWith('د.') ? rawName : `د. ${rawName}`;
              const record = {
                id: p.id,
                user_id: p.user_id,
                full_name: displayName,
                phone: u.phone || '',
                avatar_url: u.avatar_url || null,
                specialization: p.specialization || 'علاج طبيعي وتأهيل'
              };
              physioMap[p.id] = record;
              if (p.user_id) physioMap[p.user_id] = record;
            });
          }
        } catch (phErr) {
          console.warn('⚠️ تعذّر استرجاع تفاصيل أخصائي العلاج الطبيعي للحجز:', phErr);
        }
      }

      return rawBookings.map((b) => {
        const isPhysio = Boolean(b.physio_id || b.provider_type === 'physiotherapist');
        let providerData;
        if (isPhysio) {
          providerData = physioMap[b.physio_id] || { full_name: 'أخصائي علاج طبيعي معتمد' };
        } else {
          providerData = nurseMap[b.nurse_profile_id] || nurseMap[b.nurse_id] || { full_name: 'ممرض معتمد' };
        }
        const priceNum = Number(b.price ?? 0);

        return {
          ...b,
          provider_type: isPhysio ? 'physiotherapist' : 'nurse',
          is_physio: isPhysio,
          service_name: b.service_type || b.service_name || (isPhysio ? 'جلسة علاج طبيعي وتأهيل منزلي' : 'زيارة تمريضية'),
          price: priceNum,
          total_price: priceNum,
          visit_time: b.start_time || b.visit_time || '',
          notes: b.patient_notes || b.notes || '',
          patient_address: b.patient_address || '',
          nurse: providerData,
          provider: providerData
        };
      });
    },

    // ==========================================================
    // Nurse Bookings
    // ==========================================================

    async getNurseBookings(nurseId, status = null) {
      const sb = getSupabase();
      if (!sb) return [];
      if (!nurseId) throw new Error('معرّف الممرض غير موجود.');

      // ═══════════════════════════════════════════════════════════════════
      // الحماية DB-Level: نستدعي get_nurse_bookings() SECURITY DEFINER
      // بدلاً من SELECT * المباشر على جدول bookings.
      // الدالة تُخفي patient_phone/patient_address/latitude/longitude/patient_notes
      // على مستوى PostgreSQL قبل إرسال البيانات، بغض النظر عن الواجهة.
      // ═══════════════════════════════════════════════════════════════════

      const rpcParams = {};
      if (status && status !== 'all') {
        rpcParams.p_status = status;
      }

      const { data: rpcBookings, error: rpcErr } = await sb.rpc(
        'get_nurse_bookings',
        rpcParams
      );

      if (rpcErr) {
        console.error('❌ get_nurse_bookings RPC failed:', {
          message: rpcErr.message,
          code: rpcErr.code
        });

        // حماية مغلقة: ممنوع جلب بيانات المرضى باستعلام مباشر
        // عند فشل دالة الحماية في قاعدة البيانات.
        throw new Error(
          'تعذر تحميل الحجوزات بأمان. يرجى المحاولة لاحقًا أو التواصل مع الدعم.'
        );
      }

      return (rpcBookings || []).map((b) => {
        // الدالة DB ترجع is_patient_masked صحيح — نستخدمه مباشرة
        const isAcceptedOrBeyond = ['accepted', 'in_progress', 'completed'].includes(b.status);

        // إحداثيات GPS (الدالة أرجعتها NULL إذا كانت مخفية)
        let lat = b.latitude != null ? Number(b.latitude) : null;
        let lng = b.longitude != null ? Number(b.longitude) : null;

        // استخراج GPS المضمّن في النص (fallback - فقط بعد القبول)
        if (isAcceptedOrBeyond && (lat == null || lng == null)) {
          const fullText = `${b.patient_address || ''} ${b.patient_notes || ''}`;
          const gpsMatch = fullText.match(/\[GPS:\s*(-?\d+\.?\d*),\s*(-?\d+\.?\d*)\]/i);
          if (gpsMatch) {
            lat = parseFloat(gpsMatch[1]);
            lng = parseFloat(gpsMatch[2]);
          }
        }

        const gov = b.governorate || '';
        const city = b.city || '';
        const displayAddress = isAcceptedOrBeyond
          ? (b.patient_address || '')
          : (gov && city ? `${gov} - ${city}` : 'يظهر العنوان بعد قبول الطلب');

        return {
          ...b,
          patient_address: displayAddress,
          service_name: b.service_type || b.service_name || 'زيارة تمريضية',
          duration_hours: Number(b.duration_hours || 1),
          price: Number(b.price || b.total_price || 0),
          total_price: Number(b.total_price || b.price || 0),
          visit_time: b.start_time || b.visit_time || '',
          notes: isAcceptedOrBeyond ? (b.patient_notes || b.notes || '') : '',
          latitude: lat,
          longitude: lng,
          patient: isAcceptedOrBeyond
            ? { full_name: b.patient_name, phone: b.patient_phone }
            : { full_name: b.patient_name }
        };
      });
    },

    // دالة Fallback الداخلية — تُستخدم فقط إذا لم تكن migration v9 مطبّقة
    async _getNurseBookingsFallback(sb, nurseId, status) {
      let targetNurseProfileId = null;
      try {
        const { data: np } = await sb
          .from('nurse_profiles').select('id').eq('user_id', nurseId).maybeSingle();
        if (np?.id) targetNurseProfileId = np.id;
      } catch (_) { }

      let query = sb.from('bookings').select('*').order('visit_date', { ascending: true });
      if (targetNurseProfileId) {
        query = query.or(
          `nurse_id.eq.${nurseId},nurse_id.eq.${targetNurseProfileId},nurse_profile_id.eq.${targetNurseProfileId}`
        );
      } else {
        query = query.or(`nurse_id.eq.${nurseId},nurse_profile_id.eq.${nurseId}`);
      }
      if (status && status !== 'all') query = query.eq('status', status);

      const { data, error } = await query;
      if (error) throw new Error(`فشل جلب حجوزات الممرض: ${error.message || error.code}`);

      return (data || []).map((b) => {
        const isAcceptedOrBeyond = ['accepted', 'in_progress', 'completed'].includes(b.status);
        const gov = b.governorate || '';
        const city = b.city || '';
        return {
          ...b,
          // JS-layer masking (fallback فقط — الحماية الحقيقية في DB Function)
          patient_phone: isAcceptedOrBeyond ? (b.patient_phone || '') : null,
          patient_address: isAcceptedOrBeyond
            ? (b.patient_address || '')
            : (gov && city ? `${gov} - ${city}` : 'يظهر العنوان بعد قبول الطلب'),
          latitude: isAcceptedOrBeyond ? b.latitude : null,
          longitude: isAcceptedOrBeyond ? b.longitude : null,
          patient_notes: isAcceptedOrBeyond ? b.patient_notes : null,
          notes: isAcceptedOrBeyond ? (b.notes || b.patient_notes || '') : null,
          is_patient_masked: !isAcceptedOrBeyond,
          duration_hours: Number(b.duration_hours || 1),
          price: Number(b.price || b.total_price || 0),
          total_price: Number(b.total_price || b.price || 0),
        };
      });
    },

    // ==========================================================
    // Update Booking Status
    // ==========================================================

    async updateBookingStatus(bookingId, status) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      // 1. التحقق من صحة المدخلات
      if (!bookingId || typeof bookingId !== 'string' || !bookingId.trim()) {
        throw new Error('معرف الحجز مطلوب وغير صالح.');
      }
      const cleanBookingId = bookingId.trim();

      const ALLOWED_STATUSES = ['pending', 'accepted', 'rejected', 'in_progress', 'completed', 'cancelled'];
      const cleanStatus = (status || '').trim().toLowerCase();
      if (!ALLOWED_STATUSES.includes(cleanStatus)) {
        throw new Error(`حالة الحجز غير صالحة (${status}). الحالات المسموح بها: ${ALLOWED_STATUSES.join(', ')}.`);
      }

      // 2. التحقق من جلسة المستخدم الحالي
      const { data: authData, error: authErr } = await sb.auth.getUser();
      if (authErr || !authData?.user) {
        throw new Error('انتهت جلسة تسجيل الدخول. يرجى تسجيل الدخول مجدداً للمتابعة.');
      }
      const currentUser = authData.user;

      // 3. التحقق المسبق من وجود الحجز
      const { data: existingBooking, error: fetchErr } = await sb
        .from('bookings')
        .select('id, patient_id, nurse_id, status')
        .eq('id', cleanBookingId)
        .maybeSingle();

      if (fetchErr) {
        console.error('خطأ فحص الحجز:', fetchErr);
        throw new Error(`تعذر التحقق من الحجز: ${fetchErr.message || 'خطأ في الاتصال'}`);
      }

      if (!existingBooking) {
        throw new Error('الحجز غير موجود في قاعدة البيانات، أو لا تملك صلاحية الوصول إليه.');
      }

      // 4. فحص الصلاحيات المعتمدة بناءً على دور المستخدم المسجل في قاعدة البيانات profiles (لا نعتمد على user_metadata)
      const { data: prof } = await sb.from('profiles').select('role').eq('id', currentUser.id).maybeSingle();
      const userRole = prof?.role || 'patient';
      const isAdmin = userRole === 'admin';
      const isPatient = existingBooking.patient_id === currentUser.id;

      let isNurse = existingBooking.nurse_id === currentUser.id;
      if (!isNurse && userRole === 'nurse') {
        const { data: np } = await sb
          .from('nurse_profiles')
          .select('id')
          .eq('user_id', currentUser.id)
          .maybeSingle();
        if (np && np.id === existingBooking.nurse_id) {
          isNurse = true;
        }
      }

      if (!isAdmin && !isPatient && !isNurse) {
        throw new Error('ليس لديك صلاحية لتعديل حالة هذا الحجز.');
      }

      // 5. التحقق من صحة انتقال الحالة (Lifecycle Transitions) لغير المشرف
      const currentStatus = existingBooking.status;
      if (currentStatus === cleanStatus) {
        return existingBooking;
      }

      if (!isAdmin) {
        // حظر الانتقال المباشر لحالتي بدء وإنهاء الزيارة - يجب استخدام أكواد التحقق حصراً
        if (cleanStatus === 'in_progress') {
          throw new Error('غير مسموح بتغيير حالة الحجز إلى (جارية) مباشرة. يجب استخدام نظام إدخال كود تأكيد وصول الممرض.');
        }
        if (cleanStatus === 'completed') {
          throw new Error('غير مسموح بتغيير حالة الحجز إلى (مكتملة) مباشرة. يجب استخدام نظام إدخال كود تأكيد انتهاء الزيارة.');
        }

        if (isPatient) {
          if (cleanStatus !== 'cancelled') {
            throw new Error('غير مصرح للمريض إلا بإلغاء الحجز.');
          }
          if (!['pending', 'accepted'].includes(currentStatus)) {
            throw new Error(`لا يمكن إلغاء الحجز لأنه في حالة "${currentStatus}".`);
          }
        } else if (isNurse) {
          if (currentStatus === 'pending' && !['accepted', 'rejected', 'cancelled'].includes(cleanStatus)) {
            throw new Error('انتقال الحالة غير مسموح: الحجز الجديد يمكن قبوله أو رفضه أو الاعتذار عنه فقط.');
          }
          if (currentStatus === 'accepted' && cleanStatus !== 'cancelled') {
            throw new Error('انتقال الحالة غير مسموح مباشرة: الحجز المقبول يمكن إلغاؤه فقط، أو بدء الزيارة عبر كود التحقق.');
          }
          if (currentStatus === 'in_progress') {
            throw new Error('انتقال الحالة غير مسموح مباشرة: إنهاء الزيارة يتطلب إدخال كود تأكيد انتهاء الزيارة.');
          }
          if (['completed', 'cancelled', 'rejected'].includes(currentStatus)) {
            throw new Error(`لا يمكن تعديل هذا الحجز لأنه مغلق بحالة "${currentStatus}".`);
          }
        }
      }

      // 6. تنفيذ التحديث في قاعدة البيانات (بدون .single() المباشرة لتجنب PGRST116 الصامت)
      const { data: updatedRows, error: updateErr } = await sb
        .from('bookings')
        .update({
          status: cleanStatus,
          updated_at: new Date().toISOString()
        })
        .eq('id', cleanBookingId)
        .select();

      if (updateErr) {
        console.error('❌ updateBookingStatus error:', updateErr);

        // رسالة واضحة عند الوصول للحد الأقصى للمديونية
        if (updateErr.message?.includes('لا يمكن قبول الزيارة')) {
          throw new Error(
            'لا يمكنك قبول هذه الزيارة لأن إجمالي مديونيتك والعمولات المتوقعة سيتجاوز 500 جنيه. يرجى سداد جزء من مديونيتك أولاً.'
          );
        }

        if (updateErr.message?.includes('انتقال حالة الحجز غير مسموح')) {
          throw new Error('انتقال حالة الحجز غير مسموح وفقاً لقيود أمان النظام.');
        }

        throw new Error(
          `فشل تحديث الحجز في قاعدة البيانات: ${updateErr.message || updateErr.code}`
        );
      }

      if (!updatedRows || updatedRows.length === 0) {
        const { data: verifyRow } = await sb
          .from('bookings')
          .select('id, status')
          .eq('id', cleanBookingId)
          .maybeSingle();

        if (verifyRow && verifyRow.status === cleanStatus) {
          return {
            ...existingBooking,
            status: cleanStatus,
            updated_at: new Date().toISOString()
          };
        }

        console.error('❌ updateBookingStatus: 0 rows affected for bookingId:', cleanBookingId);

        throw new Error(
          'لم يتم تحديث الحجز: تم رفض التعديل بواسطة سياسة أمان قاعدة البيانات (RLS) لعدم تطابق شروط الصلاحية.'
        );
      }

      return updatedRows[0];
    },

    /**
     * جلب كود التحقق الخاص بالزيارة للمريض (لبدء أو إنهاء الزيارة)
     * يستدعي دالة RPC في قاعدة البيانات: get_patient_visit_code
     * مقيدة بصلاحية المريض صاحب الحجز حصراً ولا تُكشف للممرض أو غيره
     */
    async getPatientVisitCode(bookingId) {
      const sb = getSupabase();
      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!bookingId || typeof bookingId !== 'string' || !bookingId.trim()) {
        throw new Error('معرف الحجز مطلوب وغير صالح.');
      }
      const cleanBookingId = bookingId.trim();

      const { data, error } = await sb.rpc('get_patient_visit_code', {
        p_booking_id: cleanBookingId
      });

      if (error) {
        throw new Error(error.message || 'فشل جلب كود الزيارة.');
      }

      let res = data;
      if (typeof res === 'string') {
        try {
          res = JSON.parse(res);
        } catch (_) { }
      }

      return res || { available: false, reason: 'الكود غير متوفر حالياً.' };
    },

    /**
     * التحقق من كود الزيارة بواسطة الممرض (لبدء أو إنهاء الزيارة)
     * يستدعي Edge Function: verify-visit-code
     * المعاملة ذرية ولا يتم تعديل حالة الحجز مباشرة من المتصفح
     */
    async verifyVisitCode(bookingId, code, codeType) {
      const sb = getSupabase();
      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!bookingId || typeof bookingId !== 'string' || !bookingId.trim()) {
        throw new Error('معرف الحجز مطلوب وغير صالح.');
      }
      const cleanBookingId = bookingId.trim();

      // تنظيف الكود وتحويل الأرقام العربية إلى إنجليزية
      const cleanCode = (code || '')
        .toString()
        .replace(/[٠-٩]/g, d => String(d.charCodeAt(0) - 0x0660))
        .replace(/[۰-۹]/g, d => String(d.charCodeAt(0) - 0x06F0))
        .trim();

      if (!/^\d{6}$/.test(cleanCode)) {
        throw new Error('كود التحقق يجب أن يتكون من 6 أرقام فقط.');
      }

      const cleanType = (codeType || '').toString().trim().toLowerCase();
      if (!['start', 'end'].includes(cleanType)) {
        throw new Error('نوع كود التحقق غير صالح (يجب أن يكون start أو end).');
      }

      // التحقق من وجود جلسة مستخدم نشطة للممرض
      const { data: authData, error: authErr } = await sb.auth.getUser();
      if (authErr || !authData?.user) {
        throw new Error('انتهت جلسة تسجيل الدخول. يرجى تسجيل الدخول مجدداً للمتابعة.');
      }

      const { data, error } = await sb.functions.invoke('verify-visit-code', {
        body: {
          booking_id: cleanBookingId,
          code: cleanCode,
          code_type: cleanType
        }
      });

      if (error) {
        let errMsg = null;
        if (error.context && typeof error.context.json === 'function') {
          try {
            const errJson = await error.context.json();
            errMsg = errJson?.error || errJson?.message;
          } catch (_) { }
        }
        if (!errMsg && data?.error) {
          errMsg = data.error;
        }
        if (!errMsg && data?.message) {
          errMsg = data.message;
        }
        if (!errMsg) {
          errMsg = error.message || 'فشل الاتصال بخدمة التحقق من الكود.';
        }
        throw new Error(errMsg);
      }

      let parsed = data;
      if (typeof parsed === 'string') {
        try {
          parsed = JSON.parse(parsed);
        } catch (_) { }
      }

      if (!parsed || parsed.success !== true) {
        const failureMsg = parsed?.error || parsed?.message || 'كود التحقق غير صحيح أو غير متاح.';
        throw new Error(failureMsg);
      }

      return parsed;
    },

    // ==========================================================
    // Admin Dashboard APIs
    // ==========================================================

    // 1. جلب الإحصائيات الشاملة للوحة تحكم الإدارة
    async adminGetStats() {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      // تشخيص حساب الأدمن وصلاحياته
      const { data: { user }, error: authError } = await sb.auth.getUser();

      console.log('ADMIN USER CHECK:', {
        userId: user?.id,
        email: user?.email,
        authError: authError?.message
      });

      if (user?.id) {
        const { data: profile, error: profileError } = await sb
          .from('profiles')
          .select('id, role')
          .eq('id', user.id)
          .maybeSingle();

        console.log('ADMIN PROFILE CHECK:', {
          profile,
          profileError: profileError?.message
        });
      }
      // نستخدم الحقول الحقيقية فقط (price للسعر ولا نطلب total_price)
      // ملاحظة: physiotherapist_profiles يُجلب بشكل منفصل مع try/catch لأن الجدول قد لا يكون موجودًا دائمًا
      const [nursesRes, patientsRes, bookingsRes] = await Promise.all([
        sb.from('nurse_profiles').select('id, verified, is_active', { count: 'exact' }),
        sb.from('profiles').select('id', { count: 'exact' }).eq('role', 'patient'),
        sb.from('bookings').select('id, status, price', { count: 'exact' })
      ]);

      let physiosRes = { data: [], count: 0, error: null };
      try {
        const { data: phData, count: phCount, error: phErr } = await sb
          .from('physiotherapist_profiles')
          .select('id, verified, is_active, verification_status', { count: 'exact' });
        if (!phErr) {
          physiosRes = { data: phData || [], count: phCount ?? (phData ? phData.length : 0), error: null };
        } else {
          console.warn('⚠️ adminGetStats: physiotherapist_profiles query warning:', phErr.message);
        }
      } catch (phEx) {
        console.warn('⚠️ adminGetStats: physiotherapist_profiles exception:', phEx.message);
      }

      if (nursesRes.error) {
        console.error('❌ adminGetStats (nurses error):', nursesRes.error);
        throw new Error(`خطأ في جلب بيانات الممرضين: ${nursesRes.error.message || nursesRes.error.code}`);
      }
      if (patientsRes.error) {
        console.error('❌ adminGetStats (patients error):', patientsRes.error);
        throw new Error(`خطأ في جلب بيانات المرضى: ${patientsRes.error.message || patientsRes.error.code}`);
      }
      if (bookingsRes.error) {
        console.error('❌ adminGetStats (bookings error):', bookingsRes.error);
        throw new Error(`خطأ في جلب بيانات الحجوزات: ${bookingsRes.error.message || bookingsRes.error.code}`);
      }

      const nursesList = nursesRes.data || [];
      const bookingsList = bookingsRes.data || [];
      const physiosList = physiosRes?.data || [];

      const totalNurses = nursesRes.count ?? nursesList.length;
      const approvedNurses = nursesList.filter(n => n.verified === true && n.is_active !== false).length;
      const suspendedNurses = nursesList.filter(n => n.verified === true && n.is_active === false).length;
      const pendingNurses = nursesList.filter(n => n.verified === false).length;

      const totalPhysios = physiosRes?.count ?? physiosList.length;
      const approvedPhysios = physiosList.filter(p => p.verified === true && p.is_active !== false).length;
      const pendingPhysios = physiosList.filter(p => p.verification_status === 'pending' || (p.verified === false && p.verification_status !== 'rejected')).length;
      const rejectedPhysios = physiosList.filter(p => p.verification_status === 'rejected').length;
      const suspendedPhysios = physiosList.filter(p => p.verification_status === 'suspended' || (p.verified === true && p.is_active === false)).length;

      const totalPatients = patientsRes.count ?? (patientsRes.data ? patientsRes.data.length : 0);

      const totalBookings = bookingsRes.count ?? bookingsList.length;
      const pendingBookings = bookingsList.filter(b => b.status === 'pending').length;
      const acceptedBookings = bookingsList.filter(b => b.status === 'accepted').length;
      const completedBookings = bookingsList.filter(b => b.status === 'completed').length;
      const cancelledBookings = bookingsList.filter(b => b.status === 'cancelled' || b.status === 'rejected').length;

      // إجمالي الإيرادات من الحجوزات المكتملة فقط باستخدام عمود price الحقيقي
      const totalRevenue = bookingsList
        .filter(b => b.status === 'completed')
        .reduce((sum, b) => sum + (Number(b.price) || 0), 0);

      return {
        totalNurses,
        approvedNurses,
        pendingNurses,
        suspendedNurses,
        totalPhysios,
        approvedPhysios,
        pendingPhysios,
        rejectedPhysios,
        suspendedPhysios,
        totalPatients,
        totalBookings,
        pendingBookings,
        acceptedBookings,
        completedBookings,
        cancelledBookings,
        totalRevenue
      };
    },

    // 2. جلب جميع الحجوزات مع بيانات المرضى والممرضين والفلترة والبحث
    async adminGetAllBookings(filters = {}) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      // 1. استعلام جدول bookings مباشرة لتفادي مشاكل PostgREST foreign key embedding
      let query = sb
        .from('bookings')
        .select('*')
        .order('created_at', { ascending: false });

      if (filters.status && filters.status !== 'all') {
        query = query.eq('status', filters.status);
      }

      if (filters.startDate) {
        query = query.gte('visit_date', filters.startDate);
      }

      if (filters.endDate) {
        query = query.lte('visit_date', filters.endDate);
      }

      const { data, error } = await query;
      if (error) {
        console.error('❌ adminGetAllBookings error:', error);
        throw new Error(`تعذر جلب الحجوزات من Supabase: ${error.message || error.code}`);
      }

      const rawBookings = data || [];

      // 2. جلب بيانات المرضى الفريدين من profiles
      const patientIds = [...new Set(rawBookings.map(b => b.patient_id).filter(Boolean))];
      const patientMap = {};

      if (patientIds.length > 0) {
        try {
          const { data: pList, error: pErr } = await sb
            .from('profiles')
            .select('id, full_name, phone, email, address, governorate, city')
            .in('id', patientIds);

          if (!pErr && pList) {
            pList.forEach(p => { patientMap[p.id] = p; });
          }
        } catch (pErr) {
          console.warn('⚠️ adminGetAllBookings patient lookup warning:', pErr);
        }
      }

      // 3. جلب بيانات الممرضين: bookings.nurse_id يرتبط بـ nurse_profiles.id
      const nurseProfileIds = [...new Set(rawBookings.map(b => b.nurse_id).filter(Boolean))];
      const nurseMap = {};

      if (nurseProfileIds.length > 0) {
        try {
          // استعلام nurse_profiles
          const { data: nProfiles, error: npErr } = await sb
            .from('nurse_profiles')
            .select('id, user_id, specialization, governorate, city, visit_price')
            .in('id', nurseProfileIds);

          let nurseUserIds = [];
          if (!npErr && nProfiles) {
            nurseUserIds = [...new Set(nProfiles.map(np => np.user_id).filter(Boolean))];
          }

          // استعلام حسابات المستخدمين profiles المرتبطة بالممرضين
          let userProfileMap = {};
          if (nurseUserIds.length > 0) {
            const { data: uProfiles } = await sb
              .from('profiles')
              .select('id, full_name, phone, email, avatar_url')
              .in('id', nurseUserIds);

            if (uProfiles) {
              uProfiles.forEach(u => { userProfileMap[u.id] = u; });
            }
          }

          if (nProfiles) {
            nProfiles.forEach(np => {
              const u = userProfileMap[np.user_id] || {};
              nurseMap[np.id] = {
                id: np.id,
                user_id: np.user_id,
                full_name: u.full_name || 'ممرض',
                phone: u.phone || '',
                email: u.email || '',
                avatar_url: u.avatar_url || null,
                specialization: np.specialization || ''
              };
            });
          }

          // فحص احتياطي لأي حجز قديم قد يحمل profiles.id مباشرة
          const missingNurseIds = nurseProfileIds.filter(id => !nurseMap[id]);
          if (missingNurseIds.length > 0) {
            const { data: directProfiles } = await sb
              .from('profiles')
              .select('id, full_name, phone, email, avatar_url')
              .in('id', missingNurseIds);

            if (directProfiles) {
              directProfiles.forEach(p => {
                nurseMap[p.id] = {
                  id: p.id,
                  user_id: p.id,
                  full_name: p.full_name || 'ممرض',
                  phone: p.phone || '',
                  email: p.email || '',
                  avatar_url: p.avatar_url || null,
                  specialization: ''
                };
              });
            }
          }
        } catch (nErr) {
          console.warn('⚠️ adminGetAllBookings nurse lookup warning:', nErr);
        }
      }

      // 4. تنسيق الحجوزات مع كافة البيانات المطلوبة
      let formatted = rawBookings.map(b => {
        const patientData = patientMap[b.patient_id] || {};
        const nurseData = nurseMap[b.nurse_id] || {};

        let lat = b.latitude != null ? Number(b.latitude) : null;
        let lng = b.longitude != null ? Number(b.longitude) : null;
        if ((lat == null || isNaN(lat)) || (lng == null || isNaN(lng))) {
          const fullText = `${b.patient_address || ''} ${b.patient_notes || ''}`;
          const gpsMatch = fullText.match(/\[GPS:\s*(-?\d+\.?\d*),\s*(-?\d+\.?\d*)\]/i);
          if (gpsMatch) {
            lat = parseFloat(gpsMatch[1]);
            lng = parseFloat(gpsMatch[2]);
          }
        }

        const priceNum = Number(b.price ?? 0);

        const patientName = patientData.full_name || b.patient_name || 'غير محدد';
        const patientPhone = patientData.phone || b.patient_phone || '';
        const nurseName = nurseData.full_name || 'غير محدد';
        const nursePhone = nurseData.phone || '';

        return {
          ...b,
          booking_code: b.booking_code || (b.id ? String(b.id).slice(0, 8).toUpperCase() : '—'),
          patient_name: patientName,
          patient_phone: patientPhone,
          patient_email: patientData.email || '',
          patient_address: b.patient_address || patientData.address || '',
          nurse_name: nurseName,
          nurse_phone: nursePhone,
          nurse_specialization: nurseData.specialization || '',
          service_name: b.service_type || b.service_name || 'زيارة تمريضية',
          duration_hours: Number(b.duration_hours || 1),
          price: priceNum,
          total_price: priceNum,
          governorate: b.governorate || patientData.governorate || '—',
          city: b.city || patientData.city || '—',
          latitude: lat,
          longitude: lng,
          visit_time: b.start_time || b.visit_time || '',
          notes: b.patient_notes || b.notes || '',
          patient: patientData,
          nurse: nurseData
        };
      });

      // فلترة البحث
      if (filters.search) {
        const term = String(filters.search).toLowerCase().trim();
        formatted = formatted.filter(b => {
          return (b.booking_code && b.booking_code.toLowerCase().includes(term)) ||
            (b.patient_name && b.patient_name.toLowerCase().includes(term)) ||
            (b.patient_phone && b.patient_phone.includes(term)) ||
            (b.nurse_name && b.nurse_name.toLowerCase().includes(term)) ||
            (b.nurse_phone && b.nurse_phone.includes(term)) ||
            (b.service_name && b.service_name.toLowerCase().includes(term)) ||
            (b.governorate && b.governorate.toLowerCase().includes(term)) ||
            (b.city && b.city.toLowerCase().includes(term));
        });
      }

      return formatted;
    },

    // 3. تحديث حالة الحجز من لوحة الإدارة
    async adminUpdateBookingStatus(bookingId, status) {
      return await this.updateBookingStatus(bookingId, status);
    },

    // 4. جلب جميع طلبات ومسجلي التمريض مع الحساب الشخصي
    async adminGetAllNurses(filters = {}) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      // استعلام nurse_profiles مباشرة
      let query = sb
        .from('nurse_profiles')
        .select('*')
        .order('created_at', { ascending: false });

      if (filters.governorate) {
        query = query.eq('governorate', filters.governorate);
      }

      const { data: nProfiles, error: npErr } = await query;
      if (npErr) {
        console.error('❌ adminGetAllNurses error:', npErr);
        throw new Error(`خطأ في جلب بيانات الممرضين: ${npErr.message || npErr.code}`);
      }

      const rawNurses = nProfiles || [];
      // جلب ملفات profiles لحسابات الممرضين
      const userIds = [...new Set(rawNurses.map(n => n.user_id).filter(Boolean))];
      const profileMap = {};

      if (userIds.length > 0) {
        try {
          const { data: pList, error: pErr } = await sb
            .from('profiles')
            .select('id, full_name, email, phone, avatar_url, governorate, city, address, created_at')
            .in('id', userIds);

          if (!pErr && pList) {
            pList.forEach(p => { profileMap[p.id] = p; });
          }
        } catch (fetchErr) {
          console.warn('⚠️ adminGetAllNurses profiles lookup warning:', fetchErr);
        }
      }

      let nurses = rawNurses.map(n => {
        const p = profileMap[n.user_id] || {};
        let status = 'pending';
        if (n.verification_status) {
          status = n.verification_status;
        } else if (n.verified && n.is_active) {
          status = 'approved';
        } else if (n.verified && !n.is_active) {
          status = 'suspended';
        } else {
          status = 'pending';
        }

        return {
          id: n.id,
          user_id: n.user_id,
          full_name: p.full_name || 'غير معروف',
          email: p.email || '',
          phone: p.phone || '',
          avatar_url: p.avatar_url || null,
          national_id: '',
          specialization: n.specialization || 'تمريض عام',
          experience_years: n.experience_years ?? n.years_experience ?? 0,
          qualifications: n.qualifications || '',
          bio: n.bio || '',
          visit_price: n.visit_price || 0,
          governorate: n.governorate || p.governorate || '—',
          city: n.city || p.city || '—',
          verified: Boolean(n.verified),
          is_active: Boolean(n.is_active),
          verification_status: status,
          rejection_reason: n.rejection_reason || '',
          created_at: n.created_at || p.created_at
        };
      });

      // فلترة الحالة
      if (filters.status && filters.status !== 'all') {
        nurses = nurses.filter(n => n.verification_status === filters.status);
      }

      // فلترة البحث
      if (filters.search) {
        const term = String(filters.search).toLowerCase().trim();
        nurses = nurses.filter(n => {
          return (n.full_name && n.full_name.toLowerCase().includes(term)) ||
            (n.phone && n.phone.includes(term)) ||
            (n.email && n.email.toLowerCase().includes(term)) ||
            (n.specialization && n.specialization.toLowerCase().includes(term)) ||
            (n.governorate && n.governorate.toLowerCase().includes(term)) ||
            (n.city && n.city.toLowerCase().includes(term));
        });
      }

      return nurses;
    },

    // 5. تحديث حالة الممرض (اعتماد، رفض، إيقاف، إعادة للمراجعة)
    async adminUpdateNurseStatus(nurseUserId, action, reason = '') {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      if (!nurseUserId) {
        throw new Error('معرّف الممرض غير موجود.');
      }

      const allowedActions = [
        'approved',
        'suspended',
        'rejected',
        'pending'
      ];

      if (!allowedActions.includes(action)) {
        throw new Error('حالة الاعتماد غير صحيحة.');
      }

      const isApproved = action === 'approved';
      const isSuspended = action === 'suspended';
      const isRejected = action === 'rejected';

      const updatePayload = {
        verified: isApproved || isSuspended,
        is_active: isApproved,
        verification_status: action,
        rejection_reason: isRejected ? (reason || 'تم رفض الطلب لعدم استيفاء الشروط') : null
      };

      let { data, error } = await sb
        .from('nurse_profiles')
        .update(updatePayload)
        .eq('user_id', nurseUserId)
        .select();

      // إعادة المحاولة بالأعمدة الأساسية في حال عدم توفر verification_status في قاعدة قديمة
      if (error && (error.code === 'PGRST204' || (error.message && error.message.includes('column')))) {
        const fallbackPayload = {
          verified: isApproved || isSuspended,
          is_active: isApproved
        };
        const retry = await sb
          .from('nurse_profiles')
          .update(fallbackPayload)
          .eq('user_id', nurseUserId)
          .select();
        data = retry.data;
        error = retry.error;
      }

      if (error) {
        console.error('adminUpdateNurseStatus error:', error.message);
        throw new Error(`فشل تحديث حالة الممرض: ${error.message}`);
      }

      if (!data || data.length === 0) {
        throw new Error(
          'لم يتم تحديث بيانات الممرض. تحقق من صلاحيات الإدارة ووجود سجل الممرض.'
        );
      }

      return data;
    },

    // ==========================================================
    // 6. إدارة وفحص مستندات الممرضين الحساسة (Nurse Documents API)
    // ==========================================================

    // تسجيل المستند في جدول nurse_documents بعد رفعه إلى Storage
    async recordNurseDocumentUpload({ nurseUserId, documentType, storagePath, fileType }) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!nurseUserId || !documentType || !storagePath) {
        throw new Error('بيانات تسجيل المستند غير مكتملة.');
      }

      // 1. جلب معرف nurse_profiles.id المقترن بالممرض
      const { data: np, error: npErr } = await sb
        .from('nurse_profiles')
        .select('id')
        .eq('user_id', nurseUserId)
        .maybeSingle();

      if (npErr) {
        console.error('❌ recordNurseDocumentUpload (nurse_profile lookup):', npErr);
        throw new Error(`خطأ في الوصول لملف الممرض: ${npErr.message}`);
      }

      const nurseProfileId = np?.id;
      if (!nurseProfileId) {
        throw new Error('الملف المهني للممرض غير مسجل بعد في nurse_profiles.');
      }

      // 2. فحص السجلات السابقة لنفس نوع المستند
      let existingRecord = null;
      try {
        let q = sb.from('nurse_documents').select('id, storage_path, review_status');
        q = q.eq('nurse_id', nurseProfileId).eq('document_type', documentType);
        const { data: found } = await q.maybeSingle();
        existingRecord = found;
      } catch (findErr) {
        console.warn('⚠️ Existing doc lookup warning:', findErr);
      }

      // 3. تحديث السجل القائم أو إنشاء سجل جديد بحالة pending ومسح سبب الرفض السابق
      if (existingRecord?.id) {
        const updatePayload = {
          storage_path: storagePath,
          review_status: 'pending'
        };

        const { data: updated, error: updateErr } = await sb
          .from('nurse_documents')
          .update(updatePayload)
          .eq('id', existingRecord.id)
          .select()
          .single();

        if (updateErr) {
          console.error('❌ Error updating nurse_documents record:', updateErr);
          throw new Error(`فشل تحديث سجل المستند: ${updateErr.message || updateErr.code}`);
        }

        return updated;
      } else {
        const insertPayload = {
          nurse_id: nurseProfileId,
          document_type: documentType,
          storage_path: storagePath,
          review_status: 'pending'
        };

        const { data: inserted, error: insertErr } = await sb
          .from('nurse_documents')
          .insert(insertPayload)
          .select()
          .single();

        if (insertErr) {
          console.error('❌ Error inserting nurse_documents record:', insertErr);
          throw new Error(`فشل حفظ سجل المستند: ${insertErr.message || insertErr.code}`);
        }

        return inserted;
      }
    },

    // ==========================================================
    // 6.1 إدارة مستندات وبيانات أخصائي العلاج الطبيعي
    // ==========================================================

    async getPhysiotherapistProfile(userId) {
      const sb = getSupabase();
      if (!sb || !userId) return null;
      try {
        const { data, error } = await sb
          .from('physiotherapist_profiles')
          .select('*, profiles:user_id(*)')
          .eq('user_id', userId)
          .maybeSingle();
        if (error) {
          console.warn('⚠️ getPhysiotherapistProfile error:', error);
          return null;
        }
        return data;
      } catch (err) {
        console.warn('⚠️ getPhysiotherapistProfile exception:', err);
        return null;
      }
    },

    async setPhysiotherapistAvailability(userId, isAvailable) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!userId) throw new Error('معرّف المستخدم غير موجود.');

      const available = Boolean(isAvailable);
      const { data, error } = await sb
        .from('physiotherapist_profiles')
        .update({
          is_active: available,
          accepting_bookings: available
        })
        .eq('user_id', userId)
        .select()
        .single();

      if (error) {
        if (error.code === 'PGRST204' || (error.message && error.message.includes('column'))) {
          const retry = await sb
            .from('physiotherapist_profiles')
            .update({ is_active: available })
            .eq('user_id', userId)
            .select()
            .single();
          if (retry.error) throw retry.error;
          return retry.data;
        }
        throw error;
      }
      return data;
    },
    async getPhysiotherapistBookings(physioUserId, status = null) {
      const sb = getSupabase();
      if (!sb) return [];
      if (!physioUserId) {
        throw new Error('معرّف أخصائي العلاج الطبيعي غير موجود.');
      }

      // جلب المعرف الداخلي للملف المهني
      const { data: pp, error: ppError } = await sb
        .from('physiotherapist_profiles')
        .select('id')
        .eq('user_id', physioUserId)
        .maybeSingle();

      if (ppError) throw ppError;
      if (!pp?.id) return [];

      // جلب حجوزات أخصائي العلاج الطبيعي
      let query = sb
        .from('bookings')
        .select('*')
        .eq('physio_id', pp.id)
        .order('visit_date', { ascending: false })
        .order('created_at', { ascending: false });

      if (status && status !== 'all') {
        query = query.eq('status', status);
      }

      const { data: bookings, error } = await query;

      if (error) {
        console.error('❌ getPhysiotherapistBookings error:', error);
        throw new Error(`فشل تحميل الحجوزات: ${error.message}`);
      }

      const bookingsList = bookings || [];
      if (bookingsList.length === 0) return [];

      // جلب بيانات المرضى
      const patientIds = [
        ...new Set(bookingsList.map(b => b.patient_id).filter(Boolean))
      ];

      const patientMap = {};

      if (patientIds.length > 0) {
        const { data: patients, error: patientsError } = await sb
          .from('profiles')
          .select('id, full_name, phone, address, governorate, city')
          .in('id', patientIds);

        if (!patientsError && patients) {
          patients.forEach(p => {
            patientMap[p.id] = p;
          });
        }
      }

      // تجهيز البيانات للوحة التحكم مع إخفاء بيانات المريض قبل قبول الحجز
      return bookingsList.map(b => {
        const patient = patientMap[b.patient_id] || {};
        const accepted = ['accepted', 'in_progress', 'completed'].includes(b.status);

        const governorate = b.governorate || patient.governorate || '';
        const city = b.city || patient.city || '';

        return {
          ...b,
          service_name: b.service_name || b.service_type || 'جلسة علاج طبيعي وتأهيل',
          service_type: b.service_type || 'جلسة علاج طبيعي وتأهيل',

          patient_name: accepted
            ? (patient.full_name || 'مريض')
            : (patient.full_name
              ? patient.full_name.split(' ')[0] + ' ***'
              : 'مريض'),

          patient_phone: accepted
            ? (patient.phone || '')
            : 'مخفي قبل قبول الطلب',

          patient_address: accepted
            ? (b.patient_address || patient.address || '')
            : (governorate && city
              ? `${governorate} - ${city}`
              : 'يظهر العنوان بعد قبول الطلب'),

          governorate,
          city,
          price: Number(b.price || b.total_price || 0),
          total_price: Number(b.total_price || b.price || 0),
          is_patient_masked: !accepted
        };
      });
    },
    async upsertPhysiotherapistProfile(userId, updates) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!userId) throw new Error('معرّف المستخدم غير موجود.');

      // استبعاد الحقول التي لا يُسمح بتعديلها من خلال هذه الدالة
      const normalizedUpdates = omitKeys(updates, [
        'id',
        'user_id',
        'verified',
        'verification_status',
        'contract_status',
        'contract_rejection_reason',
        'rejection_reason',
        'reviewed_by',
        'reviewed_at',
        'created_at',
        'visit_price'
      ]);

      // توحيد اسم السعر مع قاعدة البيانات:
      // الموقع قد يرسل visit_price بينما قاعدة البيانات تستخدم session_price
      if (
        updates &&
        Object.prototype.hasOwnProperty.call(updates, 'visit_price') &&
        !Object.prototype.hasOwnProperty.call(updates, 'session_price') &&
        updates.visit_price !== undefined
      ) {
        normalizedUpdates.session_price = updates.visit_price;
      }

      const payload = {
        ...normalizedUpdates,
        user_id: userId,
        updated_at: new Date().toISOString()
      };

      const { data, error } = await sb
        .from('physiotherapist_profiles')
        .upsert(payload, {
          onConflict: 'user_id'
        })
        .select()
        .single();

      if (error) {
        console.error('❌ upsertPhysiotherapistProfile error:', error);
        throw error;
      }

      return data;
    },
    async getPhysiotherapistContractInfo(physioUserId) {
      const sb = getSupabase();
      if (!sb || !physioUserId) return null;
      try {
        const { data: pp } = await sb
          .from('physiotherapist_profiles')
          .select('id, contract_status, contract_rejection_reason, reviewed_at')
          .eq('user_id', physioUserId)
          .maybeSingle();

        let contractDoc = null;
        if (pp?.id) {
          try {
            const { data: cData, error: cErr } = await sb
              .from('physiotherapist_documents')
              .select('id, physio_id, document_type, storage_path, review_status, rejection_reason, reviewed_by, reviewed_at, created_at, updated_at')
              .eq('physio_id', pp.id)
              .eq('document_type', 'platform_contract')
              .order('created_at', { ascending: false })
              .limit(1)
              .maybeSingle();
            if (!cErr) {
              contractDoc = cData;
            }
          } catch (_) { }
        }

        let signedUrl = null;
        if (contractDoc?.storage_path) {
          try {
            const { data: sData } = await sb.storage
              .from('private-docs')
              .createSignedUrl(contractDoc.storage_path, 3600);
            signedUrl = sData?.signedUrl || null;
          } catch (_) { }
        }

        const fileName = contractDoc?.storage_path ? contractDoc.storage_path.split('/').pop() : null;

        return {
          status: contractDoc?.review_status || pp?.contract_status || 'not_uploaded',
          rejectionReason: contractDoc?.rejection_reason || pp?.contract_rejection_reason || null,
          reviewedAt: contractDoc?.reviewed_at || null,
          fileName,
          signedUrl,
          contractId: contractDoc?.id
        };
      } catch (_) {
        return null;
      }
    },

    async getPhysiotherapistWallet(physioUserId) {
      const sb = getSupabase();
      if (!sb || !physioUserId) return null;
      try {
        // الحسابات المالية المستقلة لأخصائي العلاج الطبيعي:
        // نحسب الإحصائيات من جدول bookings وجدول financial_transactions
        let physioProfileId = null;
        let sessionPrice = 0;
        try {
          const { data: pp } = await sb
            .from('physiotherapist_profiles')
            .select('id, session_price')
            .eq('user_id', physioUserId)
            .maybeSingle();
          physioProfileId = pp?.id || null;
          sessionPrice = pp?.session_price || 0;
        } catch (_) { }

        // جلب الحجوزات المكتملة للأخصائي بأمان
        let compBookings = [];
        if (physioProfileId) {
          try {
            const { data: cbData, error: cbErr } = await sb
              .from('bookings')
              .select('id, price, status')
              .eq('physio_id', physioProfileId)
              .eq('status', 'completed');
            if (!cbErr && cbData) {
              compBookings = cbData;
            }
          } catch (_) { }
        }

        const totalVisitsRev = (compBookings || []).reduce((acc, b) => acc + (Number(b.price) || 0), 0);
        // نسبة عمولة المنصة الثابتة 15%
        const totalCommsDue = Math.round(totalVisitsRev * 0.15 * 100) / 100;

        // جلب المعاملات المالية المعتمدة إن وجدت
        let settledComms = 0;
        let pendingPayouts = 0;
        let paidPayouts = 0;
        try {
          const { data: txs } = await sb
            .from('financial_transactions')
            .select('amount, type, status')
            .or(`nurse_user_id.eq.${physioUserId},patient_id.eq.${physioUserId}`);

          if (txs) {
            txs.forEach(t => {
              const amt = Number(t.amount) || 0;
              if (t.type === 'commission_settlement' && (t.status === 'approved' || t.status === 'completed')) {
                settledComms += amt;
              }
            });
          }
        } catch (_) { }

        const commissionDebt = Math.max(0, totalCommsDue - settledComms);
        const netBalance = pendingPayouts - commissionDebt;

        return {
          commission_debt: commissionDebt,
          pending_payouts: pendingPayouts,
          total_paid_payouts: paidPayouts,
          total_settled_commissions: settledComms,
          total_visits_revenue: totalVisitsRev,
          total_commissions_due: totalCommsDue,
          balance: netBalance,
          session_price: sessionPrice
        };
      } catch (_) {
        return {
          commission_debt: 0.00,
          pending_payouts: 0.00,
          total_paid_payouts: 0.00,
          total_settled_commissions: 0.00,
          total_visits_revenue: 0.00,
          total_commissions_due: 0.00,
          balance: 0.00
        };
      }
    },

    async getPhysiotherapistFinancialTransactions(physioUserId) {
      const sb = getSupabase();
      if (!sb || !physioUserId) return [];
      try {
        const { data, error } = await sb
          .from('financial_transactions')
          .select('*')
          .eq('nurse_user_id', physioUserId)
          .order('created_at', { ascending: false });

        if (error) return [];
        const txs = data || [];
        for (const t of txs) {
          if (t.receipt_path) {
            try {
              const { data: sData } = await sb.storage.from('private-docs').createSignedUrl(t.receipt_path, 3600);
              t.signed_receipt_url = sData?.signedUrl || null;
            } catch (_) { }
          }
        }
        return txs;
      } catch (_) {
        return [];
      }
    },

    async recordPhysiotherapistDocumentUpload({ physioUserId, documentType, storagePath }) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!physioUserId || !documentType || !storagePath) {
        throw new Error('بيانات تسجيل مستند العلاج الطبيعي غير مكتملة.');
      }

      // 1. جلب معرف ملف العلاج الطبيعي
      const { data: pp, error: ppErr } = await sb
        .from('physiotherapist_profiles')
        .select('id')
        .eq('user_id', physioUserId)
        .maybeSingle();

      if (ppErr || !pp?.id) {
        throw new Error('الملف المهني لأخصائي العلاج الطبيعي غير مسجل.');
      }

      const physioProfileId = pp.id;

      // 2. فحص السجلات السابقة لنفس نوع المستند
      let existingRecord = null;
      try {
        const { data: found } = await sb
          .from('physiotherapist_documents')
          .select('id, storage_path, review_status')
          .eq('physio_id', physioProfileId)
          .eq('document_type', documentType)
          .maybeSingle();
        existingRecord = found;
      } catch (_) { }

      if (existingRecord) {
        const { data: updated, error: updateErr } = await sb
          .from('physiotherapist_documents')
          .update({
            storage_path: storagePath,
            review_status: 'pending',
            rejection_reason: null,
            reviewed_by: null,
            reviewed_at: null,
            created_at: new Date().toISOString()
          })
          .eq('id', existingRecord.id)
          .select()
          .single();

        if (updateErr) throw new Error(`فشل تحديث سجل المستند: ${updateErr.message}`);
        return updated;
      } else {
        const { data: inserted, error: insertErr } = await sb
          .from('physiotherapist_documents')
          .insert({
            physio_id: physioProfileId,
            document_type: documentType,
            storage_path: storagePath,
            review_status: 'pending'
          })
          .select()
          .single();

        if (insertErr) throw new Error(`فشل حفظ سجل المستند: ${insertErr.message}`);
        return inserted;
      }
    },

    // رفع مستند للممرض إلى Storage وتسجيله في nurse_documents
    async uploadNurseDocument(userId, file, documentType) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!userId || !file || !documentType) throw new Error('بيانات الملف غير مكتملة.');

      // توحيد نوع شهادة التخرج للممرض أيضاً
      const dbDocumentType = (documentType === 'qualification_cert') ? 'graduation_cert' : documentType;

      const allowedDbTypes = ['national_id', 'syndicate_card', 'graduation_cert', 'practice_license', 'other'];
      if (!allowedDbTypes.includes(dbDocumentType)) {
        throw new Error(`نوع المستند "${dbDocumentType}" غير مدعوم للممرض.`);
      }

      const allowedMimes = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
      if (!allowedMimes.includes(file.type)) {
        throw new Error('نوع الملف غير مدعوم. يرجى رفع ملف PDF أو صورة (PNG, JPG, WEBP).');
      }
      if (file.size > 5 * 1024 * 1024) {
        throw new Error('حجم الملف يتجاوز الحد الأقصى المسموح (5 ميجابايت).');
      }

      const ext = (file.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '');
      const storagePath = `${userId}/nurse_${dbDocumentType}_${Date.now()}.${ext}`;

      const { error: uploadErr } = await sb.storage
        .from('private-docs')
        .upload(storagePath, file, {
          cacheControl: '3600',
          contentType: file.type,
          upsert: true
        });

      if (uploadErr) {
        throw new Error(`فشل رفع المستند إلى التخزين: ${uploadErr.message}`);
      }

      try {
        await this.recordNurseDocumentUpload({
          nurseUserId: userId,
          documentType: dbDocumentType,
          storagePath: storagePath
        });
      } catch (recordErr) {
        try {
          await sb.storage.from('private-docs').remove([storagePath]);
        } catch (_) { }
        throw recordErr;
      }

      return { success: true, storagePath: storagePath };
    },

    async uploadPhysiotherapistDocument(userId, file, documentType) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!userId || !file || !documentType) throw new Error('بيانات الملف غير مكتملة.');

      // توحيد نوع شهادة التخرج: qualification_cert → graduation_cert (ما تسمح به قاعدة البيانات)
      const dbDocumentType = (documentType === 'qualification_cert') ? 'graduation_cert' : documentType;

      // Validations
      const allowedDbTypes = ['national_id', 'syndicate_card', 'graduation_cert', 'practice_license', 'contract', 'platform_contract', 'other'];
      if (!allowedDbTypes.includes(dbDocumentType)) {
        throw new Error(`نوع المستند "${dbDocumentType}" غير مدعوم.`);
      }

      const allowedMimes = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
      if (!allowedMimes.includes(file.type)) {
        throw new Error('نوع الملف غير مدعوم. يرجى رفع ملف PDF أو صورة (PNG, JPG, WEBP).');
      }
      if (file.size > 5 * 1024 * 1024) {
        throw new Error('حجم الملف يتجاوز الحد الأقصى المسموح (5 ميجابايت).');
      }

      const ext = (file.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '');
      // استخدم dbDocumentType في مسار التخزين لاتساق الملفات مع قاعدة البيانات
      const storagePath = `${userId}/${dbDocumentType}_${Date.now()}.${ext}`;

      const { error: uploadErr } = await sb.storage
        .from('private-docs')
        .upload(storagePath, file, {
          cacheControl: '3600',
          contentType: file.type,
          upsert: true
        });

      if (uploadErr) {
        throw new Error(`فشل رفع المستند إلى التخزين: ${uploadErr.message}`);
      }

      try {
        await this.recordPhysiotherapistDocumentUpload({
          physioUserId: userId,
          documentType: dbDocumentType,
          storagePath: storagePath
        });
      } catch (recordErr) {
        // Rollback storage file on DB record failure
        try {
          await sb.storage.from('private-docs').remove([storagePath]);
        } catch (_) { }
        throw recordErr;
      }

      return { success: true, storagePath: storagePath };
    },

    // ----------------------------------------------------------
    // لوحة تحكم الإدارة: إدارة أخصائيي العلاج الطبيعي ومستنداتهم وعقودهم
    // ----------------------------------------------------------

    async adminGetAllPhysiotherapists(filters = {}) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      let query = sb
        .from('physiotherapist_profiles')
        .select('*')
        .order('created_at', { ascending: false });

      if (filters.governorate) {
        query = query.eq('governorate', filters.governorate);
      }

      const { data: pProfiles, error: ppErr } = await query;
      if (ppErr) {
        console.error('❌ adminGetAllPhysiotherapists error:', ppErr);
        throw new Error(`خطأ في جلب بيانات أخصائيي العلاج الطبيعي: ${ppErr.message || ppErr.code}`);
      }

      const rawPhysios = pProfiles || [];
      const userIds = [...new Set(rawPhysios.map(p => p.user_id).filter(Boolean))];
      const profileMap = {};

      if (userIds.length > 0) {
        try {
          const { data: pList, error: pErr } = await sb
            .from('profiles')
            .select('id, full_name, email, phone, avatar_url, governorate, city, address, created_at')
            .in('id', userIds);

          if (!pErr && pList) {
            pList.forEach(p => { profileMap[p.id] = p; });
          }
        } catch (fetchErr) {
          console.warn('⚠️ adminGetAllPhysiotherapists profiles lookup warning:', fetchErr);
        }
      }

      // جلب عقود أخصائيي العلاج الطبيعي من physiotherapist_documents بـ document_type = 'platform_contract'
      // (physiotherapist_contracts غير موجود، نستخدم physiotherapist_documents بدلاً منه)
      const contractMap = {};
      const physioProfileIds = rawPhysios.map(ph => ph.id).filter(Boolean);
      if (physioProfileIds.length > 0) {
        try {
          const { data: cList } = await sb
            .from('physiotherapist_documents')
            .select('id, physio_id, review_status, storage_path, rejection_reason, reviewed_at, created_at')
            .in('physio_id', physioProfileIds)
            .eq('document_type', 'platform_contract')
            .order('created_at', { ascending: false });
          if (cList) {
            // physio_id يرتبط بـ physiotherapist_profiles.id؛ نبني خريطة physio_id -> contract
            cList.forEach(c => {
              if (!contractMap[c.physio_id]) contractMap[c.physio_id] = c;
            });
          }
        } catch (cEx) {
          console.warn('⚠️ adminGetAllPhysiotherapists contract lookup warning:', cEx.message);
        }
      }

      let physios = rawPhysios.map(ph => {
        const p = profileMap[ph.user_id] || {};
        // contractMap مفهرسة بـ physio_id (= physiotherapist_profiles.id)
        const c = contractMap[ph.id] || null;

        let status = 'pending';
        if (ph.verification_status) {
          status = ph.verification_status;
        } else if (ph.verified && ph.is_active) {
          status = 'approved';
        } else if (ph.verified && !ph.is_active) {
          status = 'suspended';
        } else {
          status = 'pending';
        }

        // review_status من physiotherapist_documents يعكس حالة العقد
        const contractStatus = c?.review_status || ph.contract_status || 'not_uploaded';

        return {
          id: ph.id,
          user_id: ph.user_id,
          full_name: p.full_name || 'غير معروف',
          email: p.email || '',
          phone: p.phone || '',
          avatar_url: p.avatar_url || null,
          specialization: ph.specialization || 'العلاج الطبيعي والتأهيل',
          experience_years: ph.experience_years || 0,
          qualifications: ph.qualifications || '',
          license_number: ph.license_number || '',
          bio: ph.bio || '',
          session_price: ph.session_price || 0,
          governorate: ph.governorate || p.governorate || '—',
          city: ph.city || p.city || '—',
          address: p.address || '—',
          created_at: p.created_at || ph.created_at,
          verified: ph.verified === true,
          is_active: ph.is_active === true,
          accepting_bookings: ph.accepting_bookings === true,
          verification_status: status,
          contract_status: contractStatus,
          contract: c,
          rejection_reason: ph.rejection_reason || '',
          contract_rejection_reason: ph.contract_rejection_reason || c?.rejection_reason || ''
        };
      });

      // Filter by status if specified
      if (filters.status && filters.status !== 'all') {
        physios = physios.filter(ph => {
          if (filters.status === 'pending') return ph.verification_status === 'pending';
          if (filters.status === 'approved') return ph.verification_status === 'approved';
          if (filters.status === 'rejected') return ph.verification_status === 'rejected';
          if (filters.status === 'suspended') return ph.verification_status === 'suspended' || (!ph.is_active && ph.verified);
          return true;
        });
      }

      // Filter by search
      if (filters.search && filters.search.trim()) {
        const q = filters.search.trim().toLowerCase();
        physios = physios.filter(ph =>
          (ph.full_name && ph.full_name.toLowerCase().includes(q)) ||
          (ph.email && ph.email.toLowerCase().includes(q)) ||
          (ph.phone && ph.phone.includes(q)) ||
          (ph.specialization && ph.specialization.toLowerCase().includes(q)) ||
          (ph.governorate && ph.governorate.toLowerCase().includes(q)) ||
          (ph.city && ph.city.toLowerCase().includes(q)) ||
          (ph.license_number && ph.license_number.toLowerCase().includes(q))
        );
      }

      return physios;
    },

    // getPhysiotherapistDocuments: دالة الأخصائي لقراءة مستنداته الخاصة
    // تعمل باستخدام RLS التي تسمح له بقراءة صفوفه فقط من physiotherapist_documents
    // ترجع نفس شكل البيانات الذي تتوقعه loadPhysioDocuments في لوحة التحكم
    async getPhysiotherapistDocuments(physioUserId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!physioUserId) throw new Error('معرّف المستخدم مطلوب.');

      // خريطة الأنواع المدعومة: مفتاح قاعدة البيانات → uiKey (المُستخدم في HTML)
      const dbToUiTypeMap = {
        national_id: 'national_id',
        syndicate_card: 'syndicate_card',
        practice_license: 'practice_license',
        graduation_cert: 'qualification_cert'   // DB يخزن graduation_cert، الواجهة تعرض qualification_cert
      };

      const docMeta = {
        national_id: { title: 'بطاقة الرقم القومي (الوجهين)', icon: '🪪' },
        syndicate_card: { title: 'كارنيه نقابة العلاج الطبيعي', icon: '🏛️' },
        practice_license: { title: 'ترخيص مزاولة المهنة', icon: '📜' },
        graduation_cert: { title: 'شهادة التخرج / المؤهل الدراسي', icon: '🎓' }
      };

      // 1. جلب physio_id من physiotherapist_profiles
      let physioProfileId = null;
      try {
        const { data: pp, error: ppErr } = await sb
          .from('physiotherapist_profiles')
          .select('id')
          .eq('user_id', physioUserId)
          .maybeSingle();
        if (!ppErr && pp?.id) physioProfileId = pp.id;
      } catch (_) { }

      if (!physioProfileId) {
        // الملف المهني غير مكتمل أو غير موجود — نُرجع قائمة فارغة
        return { documents: [], contract: null, summary: { readyForApproval: false, totalUploaded: 0 } };
      }

      // 2. جلب مستندات هذا الأخصائي من physiotherapist_documents
      let rawDocs = [];
      try {
        const { data: docs, error: docsErr } = await sb
          .from('physiotherapist_documents')
          .select('id, physio_id, document_type, storage_path, review_status, rejection_reason, reviewed_at, created_at, updated_at')
          .eq('physio_id', physioProfileId);
        if (!docsErr && docs) rawDocs = docs;
        else if (docsErr) console.warn('⚠️ getPhysiotherapistDocuments fetch warning:', docsErr.message);
      } catch (_) { }

      // 3. بناء documentsList مع Signed URLs وترجمة أنواع DB → UI
      const processedUiKeys = new Set();
      const documents = [];

      for (const rec of rawDocs) {
        if (rec.document_type === 'platform_contract') continue; // العقد يُعالج منفصلاً

        const uiKey = dbToUiTypeMap[rec.document_type] || rec.document_type;
        const meta = docMeta[rec.document_type] || { title: rec.document_type, icon: '📄' };

        let signedUrl = '';
        if (rec.storage_path) {
          try {
            const { data: sData } = await sb.storage
              .from('private-docs')
              .createSignedUrl(rec.storage_path, 3600);
            signedUrl = sData?.signedUrl || '';
          } catch (_) { }
        }

        const fileName = rec.storage_path ? rec.storage_path.split('/').pop() : '';

        documents.push({
          id: rec.id,
          document_type: uiKey,          // qualification_cert للواجهة
          db_document_type: rec.document_type,  // graduation_cert في قاعدة البيانات
          document_title: meta.title,
          icon: meta.icon,
          file_name: fileName,
          storage_path: rec.storage_path,
          signed_url: signedUrl,
          is_pdf: fileName.toLowerCase().endsWith('.pdf'),
          review_status: rec.review_status || 'pending',
          rejection_reason: rec.rejection_reason || '',
          reviewed_at: rec.reviewed_at,
          created_at: rec.created_at
        });

        processedUiKeys.add(uiKey);
        processedUiKeys.add(rec.document_type);
      }

      // 4. أضف المستندات الغائبة بحالة not_uploaded
      for (const [dbType, meta] of Object.entries(docMeta)) {
        const uiKey = dbToUiTypeMap[dbType] || dbType;
        if (!processedUiKeys.has(uiKey) && !processedUiKeys.has(dbType)) {
          documents.push({
            id: `missing-${uiKey}`,
            document_type: uiKey,
            db_document_type: dbType,
            document_title: meta.title,
            icon: meta.icon,
            file_name: '',
            storage_path: '',
            signed_url: '',
            is_pdf: false,
            review_status: 'not_uploaded',
            rejection_reason: '',
            reviewed_at: null,
            created_at: null
          });
        }
      }

      const totalUploaded = documents.filter(d => d.review_status !== 'not_uploaded').length;

      return {
        documents,
        contract: null,
        summary: { readyForApproval: false, totalUploaded }
      };
    },

    async adminGetPhysiotherapistDocuments(physioUserId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!physioUserId) throw new Error('معرّف الأخصائي مطلوب.');

      // docTypeMeta: المفاتيح تعكس ما يُخزن فعلاً في قاعدة البيانات
      // graduation_cert = ما يقبله CHECK constraint بدلاً من qualification_cert
      const docTypeMeta = {
        national_id: { title: 'بطاقة الرقم القومي (الوجهين)', icon: '🪪', required: true, uiKey: 'national_id' },
        syndicate_card: { title: 'كارنيه نقابة العلاج الطبيعي', icon: '🏛️', required: true, uiKey: 'syndicate_card' },
        practice_license: { title: 'ترخيص مزاولة المهنة', icon: '📜', required: true, uiKey: 'practice_license' },
        graduation_cert: { title: 'شهادة التخرج / المؤهل الدراسي', icon: '🎓', required: true, uiKey: 'qualification_cert' }
      };

      // 1. Get physiotherapist profile
      let physioProfileId = null;
      let physioProfile = null;
      try {
        const { data: pp } = await sb
          .from('physiotherapist_profiles')
          .select('*')
          .eq('user_id', physioUserId)
          .maybeSingle();
        physioProfile = pp;
        physioProfileId = pp?.id || null;
      } catch (_) { }

      // 2. Query physiotherapist_documents (all doc types including platform_contract)
      let recordedDocs = [];
      if (physioProfileId) {
        try {
          const { data: rDocs, error: rdErr } = await sb
            .from('physiotherapist_documents')
            .select('id, physio_id, document_type, storage_path, review_status, rejection_reason, reviewed_by, reviewed_at, created_at, updated_at')
            .eq('physio_id', physioProfileId);
          if (!rdErr && rDocs) {
            recordedDocs = rDocs;
          } else if (rdErr) {
            console.warn('⚠️ adminGetPhysiotherapistDocuments warning:', rdErr.message);
          }
        } catch (_) { }
      }

      // 3. استخرج عقد المنصة من physiotherapist_documents بـ document_type='platform_contract'
      // (physiotherapist_contracts غير موجود — نستخدم physiotherapist_documents بدلاً منه)
      let contractRecord = null;
      if (physioProfileId) {
        const contractDoc = recordedDocs.find(d => d.document_type === 'platform_contract') || null;
        if (contractDoc) {
          contractRecord = {
            id: contractDoc.id,
            physio_id: contractDoc.physio_id,
            storage_path: contractDoc.storage_path,
            status: contractDoc.review_status,         // نعيد تسمية review_status كـ status للتوافق مع الواجهة
            review_status: contractDoc.review_status,
            rejection_reason: contractDoc.rejection_reason,
            reviewed_by: contractDoc.reviewed_by,
            reviewed_at: contractDoc.reviewed_at,
            created_at: contractDoc.created_at
          };
        }
      }

      // 4. Build documents with signed URLs (نستثني platform_contract — يُعالج منفصلاً كعقد)
      const processedTypes = new Set();
      const documentsList = [];

      for (const rec of recordedDocs) {
        // platform_contract يُعالج منفصلاً في قسم العقد وليس كمستند عادي
        if (rec.document_type === 'platform_contract') continue;

        // تحويل graduation_cert → qualification_cert في مفتاح الواجهة (uiKey)
        // حتى تتطابق معرفات HTML التي تعتمد على qualification_cert
        const dbType = rec.document_type;
        const meta = docTypeMeta[dbType] || { title: dbType, icon: '📄', required: false, uiKey: dbType };
        const uiDocType = meta.uiKey || dbType;

        let signedUrl = '';
        if (rec.storage_path) {
          try {
            const { data: sData } = await sb.storage
              .from('private-docs')
              .createSignedUrl(rec.storage_path, 3600);
            signedUrl = sData?.signedUrl || '';
          } catch (_) { }
        }
        const fileName = rec.storage_path ? rec.storage_path.split('/').pop() : '';
        const isPdf = fileName.toLowerCase().endsWith('.pdf');

        documentsList.push({
          id: rec.id,
          physio_id: physioProfileId,
          physio_user_id: physioUserId,
          document_type: uiDocType,      // القيمة التي تستخدمها الواجهة (qualification_cert)
          db_document_type: dbType,       // القيمة الفعلية في قاعدة البيانات (graduation_cert)
          document_title: meta.title,
          icon: meta.icon,
          is_required: meta.required,
          file_name: fileName,
          storage_path: rec.storage_path,
          signed_url: signedUrl,
          is_pdf: isPdf,
          created_at: rec.created_at,
          review_status: rec.review_status || 'pending',
          rejection_reason: rec.rejection_reason || ''
        });

        // نسجل كلا النوعين لتفادي ظهور المستند كـ "لم يُرفع" مرتين
        processedTypes.add(dbType);
        processedTypes.add(uiDocType);
      }

      // Add missing required docs as not_uploaded
      // نتحقق بناءً على uiKey (qualification_cert) لتوافق HTML
      for (const [dbType, meta] of Object.entries(docTypeMeta)) {
        const uiKey = meta.uiKey || dbType;
        if (!processedTypes.has(dbType) && !processedTypes.has(uiKey)) {
          documentsList.push({
            id: `missing-${uiKey}`,
            physio_id: physioProfileId,
            physio_user_id: physioUserId,
            document_type: uiKey,
            db_document_type: dbType,
            document_title: meta.title,
            icon: meta.icon,
            is_required: meta.required,
            file_name: '',
            storage_path: '',
            signed_url: '',
            is_pdf: false,
            created_at: null,
            review_status: 'not_uploaded',
            rejection_reason: ''
          });
        }
      }

      // Signed URL for contract
      let contractSignedUrl = '';
      if (contractRecord?.storage_path) {
        try {
          const { data: cSign } = await sb.storage
            .from('private-docs')
            .createSignedUrl(contractRecord.storage_path, 3600);
          contractSignedUrl = cSign?.signedUrl || '';
        } catch (_) { }
      }

      // Calculate readiness for approval
      // mandatoryTypes تستخدم uiKey (qualification_cert) لأن documentsList يخزن document_type بقيم الواجهة
      const mandatoryTypes = ['national_id', 'syndicate_card', 'practice_license', 'qualification_cert'];
      // docTypeMetaByUiKey: للبحث بقيمة uiKey عند بناء رسائل الأخطاء
      const docTypeMetaByUiKey = {};
      for (const [dbType, meta] of Object.entries(docTypeMeta)) {
        const uiKey = meta.uiKey || dbType;
        docTypeMetaByUiKey[uiKey] = meta;
      }
      const missingMandatory = [];
      const pendingMandatory = [];
      const rejectedMandatory = [];
      let docsApproved = true;

      for (const mType of mandatoryTypes) {
        const item = documentsList.find(d => d.document_type === mType);
        const metaForType = docTypeMetaByUiKey[mType] || { title: mType };
        if (!item || item.review_status === 'not_uploaded') {
          missingMandatory.push(metaForType.title);
          docsApproved = false;
        } else if (item.review_status === 'rejected') {
          rejectedMandatory.push(metaForType.title);
          docsApproved = false;
        } else if (item.review_status === 'pending') {
          pendingMandatory.push(metaForType.title);
          docsApproved = false;
        }
      }

      // contractStatus: نقرأ review_status لأن contractRecord مبني من physiotherapist_documents
      const contractStatus = contractRecord?.review_status || contractRecord?.status || physioProfile?.contract_status || 'not_uploaded';
      const contractApproved = contractStatus === 'approved';
      const readyForApproval = docsApproved && contractApproved;

      return {
        documents: documentsList,
        contract: contractRecord ? {
          ...contractRecord,
          // استخرج اسم الملف من storage_path لأن physiotherapist_documents لا يحتوي على عمود file_name
          file_name: contractRecord.file_name || (contractRecord.storage_path ? contractRecord.storage_path.split('/').pop() : '—'),
          // للتوافق مع الواجهة: status = review_status
          status: contractRecord.review_status || contractRecord.status,
          signed_url: contractSignedUrl,
          is_pdf: contractRecord.storage_path?.toLowerCase().endsWith('.pdf') || true
        } : null,
        summary: {
          readyForApproval,
          docsApproved,
          contractApproved,
          contractStatus,
          missingMandatory,
          pendingMandatory,
          rejectedMandatory,
          totalUploaded: documentsList.filter(d => d.review_status !== 'not_uploaded').length
        }
      };
    },

    async adminUpdatePhysiotherapistDocumentStatus(physioUserId, documentType, storagePath, newStatus, rejectionReason = '') {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!physioUserId || !documentType) {
        throw new Error('معرف الأخصائي ونوع المستند مطلوبان.');
      }

      // ترجمة qualification_cert → graduation_cert لأن قاعدة البيانات تخزن graduation_cert
      const dbDocumentType = (documentType === 'qualification_cert') ? 'graduation_cert' : documentType;

      const { data: pp, error: ppErr } = await sb
        .from('physiotherapist_profiles')
        .select('id')
        .eq('user_id', physioUserId)
        .maybeSingle();

      if (ppErr || !pp?.id) throw new Error('الملف المهني لأخصائي العلاج الطبيعي غير مسجل.');

      const { data: { user } } = await sb.auth.getUser();
      const adminId = user?.id || null;

      const updatePayload = {
        review_status: newStatus,
        rejection_reason: newStatus === 'rejected' ? rejectionReason : null,
        reviewed_by: adminId,
        reviewed_at: new Date().toISOString()
      };

      let query = sb
        .from('physiotherapist_documents')
        .update(updatePayload)
        .eq('physio_id', pp.id);

      if (storagePath) {
        query = query.eq('storage_path', storagePath);
      } else {
        query = query.eq('document_type', dbDocumentType);
      }

      const { data, error } = await query.select();
      if (error) throw new Error(`فشل تحديث حالة المستند: ${error.message}`);
      return data;
    },

    async adminUpdatePhysiotherapistStatus(physioUserId, action, reason = '') {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!physioUserId) throw new Error('معرّف الأخصائي غير موجود.');

      const allowedActions = ['approved', 'suspended', 'rejected', 'pending'];
      if (!allowedActions.includes(action)) throw new Error('حالة الاعتماد غير صحيحة.');

      // Try RPC first
      try {
        const { data: rpcRes, error: rpcErr } = await sb.rpc('admin_update_physiotherapist_status', {
          p_physio_user_id: physioUserId,
          p_action: action,
          p_reason: reason
        });
        if (!rpcErr && rpcRes) {
          if (rpcRes.success === false) throw new Error(rpcRes.error || 'فشل تحديث الحالة');
          return rpcRes;
        }
      } catch (rpcEx) {
        if (rpcEx.message && rpcEx.message.includes('لا يمكن اعتماد الأخصائي قبل')) {
          throw rpcEx;
        }
        console.warn('admin_update_physiotherapist_status RPC not available, using direct update fallback:', rpcEx);
      }

      // Fallback direct update
      const { data: { user } } = await sb.auth.getUser();
      const adminId = user?.id || null;

      const isApproved = action === 'approved';
      const isSuspended = action === 'suspended';
      const isRejected = action === 'rejected';

      const updatePayload = {
        verified: isApproved,
        is_active: isApproved,
        accepting_bookings: isApproved,
        verification_status: action,
        rejection_reason: isRejected ? (reason || 'تم رفض الطلب لعدم استيفاء الشروط') : null,
        reviewed_by: adminId,
        reviewed_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      };

      const { data, error } = await sb
        .from('physiotherapist_profiles')
        .update(updatePayload)
        .eq('user_id', physioUserId)
        .select();

      if (error) throw new Error(`فشل تحديث حالة أخصائي العلاج الطبيعي: ${error.message}`);
      return data;
    },

    // جلب جميع عقود أخصائيي العلاج الطبيعي من physiotherapist_documents
    // (physiotherapist_contracts غير موجود — نستخدم physiotherapist_documents بـ document_type='platform_contract')
    async adminGetAllPhysiotherapistContracts(options = {}) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      let query = sb
        .from('physiotherapist_documents')
        .select('id, physio_id, document_type, storage_path, review_status, rejection_reason, reviewed_by, reviewed_at, created_at, updated_at')
        .eq('document_type', 'platform_contract')
        .order('created_at', { ascending: false });

      if (options && options.status && options.status !== 'all') {
        query = query.eq('review_status', options.status);
      }

      const { data, error } = await query;
      if (error) {
        console.warn('adminGetAllPhysiotherapistContracts query error:', error);
        return [];
      }

      const contracts = data || [];

      // جلب physio_id -> physiotherapist_profiles -> user_id -> profiles
      const physioProfileIds = [...new Set(contracts.map(c => c.physio_id).filter(Boolean))];
      const physioProfileMap = {};
      const userProfileMap = {};

      if (physioProfileIds.length > 0) {
        try {
          const { data: ppList } = await sb
            .from('physiotherapist_profiles')
            .select('id, user_id')
            .in('id', physioProfileIds);
          if (ppList) {
            const userIds = [...new Set(ppList.map(pp => pp.user_id).filter(Boolean))];
            ppList.forEach(pp => { physioProfileMap[pp.id] = pp; });

            if (userIds.length > 0) {
              const { data: uList } = await sb
                .from('profiles')
                .select('id, full_name, phone, email')
                .in('id', userIds);
              if (uList) uList.forEach(u => { userProfileMap[u.id] = u; });
            }
          }
        } catch (_) { }
      }

      const results = [];
      for (const c of contracts) {
        let signedUrl = '';
        if (c.storage_path) {
          try {
            const { data: sData } = await sb.storage.from('private-docs').createSignedUrl(c.storage_path, 3600);
            signedUrl = sData?.signedUrl || '';
          } catch (_) { }
        }
        const pp = physioProfileMap[c.physio_id] || {};
        const u = userProfileMap[pp.user_id] || {};
        results.push({
          ...c,
          physio_user_id: pp.user_id || null,
          // للتوافق مع الواجهة: نعيد status = review_status
          status: c.review_status,
          physio_name: u.full_name || 'أخصائي علاج طبيعي',
          physio_phone: u.phone || '—',
          physio_email: u.email || '—',
          signed_url: signedUrl,
          signedUrl: signedUrl
        });
      }
      return results;
    },

    // مراجعة عقد المنصة الخاص بأخصائي (قبول/رفض) عبر physiotherapist_documents
    async adminReviewPhysiotherapistContract(contractId, newStatus, rejectionReason = null) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const { data: { user } } = await sb.auth.getUser();
      const adminId = user?.id || null;

      // تحديث سجل physiotherapist_documents مباشرة
      const { data: updatedDoc, error: cErr } = await sb
        .from('physiotherapist_documents')
        .update({
          review_status: newStatus,
          rejection_reason: newStatus === 'rejected' ? (rejectionReason || '') : null,
          reviewed_by: adminId,
          reviewed_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        })
        .eq('id', contractId)
        .eq('document_type', 'platform_contract')
        .select()
        .single();

      if (cErr) throw new Error(`فشل تحديث العقد: ${cErr.message}`);

      // تحديث contract_status في physiotherapist_profiles للتوافق مع واجهات أخرى
      if (updatedDoc?.physio_id) {
        try {
          await sb.from('physiotherapist_profiles').update({
            contract_status: newStatus
          }).eq('id', updatedDoc.physio_id);
        } catch (_) { }
      }

      return { success: true };
    },

    // رفع عقد المنصة من قِبل الأخصائي — يُخزَّن في physiotherapist_documents بـ document_type='platform_contract'
    async submitPhysiotherapistContract(file) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data: { user } } = await sb.auth.getUser();
      if (!user) throw new Error('يجب تسجيل الدخول أولاً.');

      const allowedMimes = ['application/pdf', 'image/jpeg', 'image/png'];
      if (!allowedMimes.includes(file.type)) {
        throw new Error('نوع ملف العقد غير مدعوم (PDF أو صورة).');
      }
      if (file.size > 5 * 1024 * 1024) {
        throw new Error('حجم الملف يتجاوز الحد الأقصى (5 ميجابايت).');
      }

      const ext = (file.name.split('.').pop() || 'pdf').toLowerCase().replace(/[^a-z0-9]/g, '');
      // مسار التخزين داخل private-docs/{userId}/... بنفس منهج المستندات الأخرى
      const storagePath = `${user.id}/platform_contract_${Date.now()}.${ext}`;

      const { error: upErr } = await sb.storage.from('private-docs').upload(storagePath, file, {
        cacheControl: '3600',
        contentType: file.type,
        upsert: true
      });

      if (upErr) throw new Error('فشل رفع العقد: ' + upErr.message);

      try {
        // جلب physiotherapist_profiles.id للأخصائي
        const { data: pp } = await sb
          .from('physiotherapist_profiles')
          .select('id')
          .eq('user_id', user.id)
          .maybeSingle();
        if (!pp?.id) throw new Error('الملف المهني غير مسجل. يرجى إكمال تسجيل ملفك المهني أولاً.');

        // استخدام recordPhysiotherapistDocumentUpload لحفظ العقد في physiotherapist_documents
        await this.recordPhysiotherapistDocumentUpload({
          physioUserId: user.id,
          documentType: 'platform_contract',
          storagePath: storagePath
        });
      } catch (recordErr) {
        // تنظيف الملف المرفوع في حال فشل تسجيل الداتابيز لتجنب الملفات اليتيمة
        try {
          await sb.storage.from('private-docs').remove([storagePath]);
        } catch (_) { }
        throw recordErr;
      }

      return { success: true, storagePath };
    },

    // جلب قائمة مستندات الممرض مع Signed URLs مؤقتة (آمنة وبدون Public URLs)
    async adminGetNurseDocuments(nurseUserId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!nurseUserId) throw new Error('معرّف الممرض مطلوب.');

      const docTypeMeta = {
        id_front: { title: 'بطاقة الرقم القومي (الوجه الأمامي)', icon: '🪪', required: true },
        id_back: { title: 'بطاقة الرقم القومي (الوجه الخلفي)', icon: '🪪', required: true },
        certificate: { title: 'شهادة التخرج / المؤهل الدراسي', icon: '🎓', required: true },
        license: { title: 'ترخيص مزاولة المهنة', icon: '📜', required: false },
      };

      // 1. جلب معرف nurse_profiles.id
      let nurseProfileId = null;
      try {
        const { data: np } = await sb
          .from('nurse_profiles')
          .select('id')
          .eq('user_id', nurseUserId)
          .maybeSingle();
        nurseProfileId = np?.id || null;
      } catch (_) { }

      // 2. فحص المستندات المسجلة في جدول nurse_documents
      let recordedDocs = [];
      if (nurseProfileId) {
        try {
          const { data: dbDocs, error: dbErr } = await sb
            .from('nurse_documents')
            .select('*')
            .eq('nurse_id', nurseProfileId)
            .order('created_at', { ascending: false });

          if (!dbErr && dbDocs) {
            recordedDocs = dbDocs;
          }
        } catch (tableErr) {
          console.warn('⚠️ nurse_documents table select warning:', tableErr);
        }
      }

      // 3. استرجاع الملفات المرفوعة فعلياً في Storage (Private Bucket: private-docs)
      let storageFiles = [];
      try {
        const { data: files, error: listError } = await sb.storage
          .from('private-docs')
          .list(nurseUserId, {
            limit: 100,
            sortBy: { column: 'created_at', order: 'desc' }
          });

        if (!listError && files) {
          storageFiles = files.filter(f => f.name && !f.name.startsWith('.'));
        }
      } catch (storageErr) {
        console.warn('⚠️ Private docs storage list warning:', storageErr);
      }

      // 4. توليد Signed URLs آمنة ومؤقتة لكل ملف موجود في Storage
      const documentsList = [];
      const handledStoragePaths = new Set();
      const processedTypes = new Set();

      for (const file of storageFiles) {
        const fileName = file.name;
        const filePath = `${nurseUserId}/${fileName}`;
        handledStoragePaths.add(filePath);

        // استنتاج نوع المستند من اسم الملف (مثل id_front_12345.jpg)
        let matchedType = null;
        for (const type of Object.keys(docTypeMeta)) {
          if (fileName.startsWith(type)) {
            matchedType = type;
            break;
          }
        }

        // تجاهل الملفات من أنواع غير معروفة (مثل experience_ أو training_ القديمة)
        if (!matchedType) continue;

        const meta = docTypeMeta[matchedType];

        // توليد Signed URL مؤقت
        let signedUrl = '';
        try {
          const { data: signedData } = await sb.storage
            .from('private-docs')
            .createSignedUrl(filePath, 3600);
          signedUrl = signedData?.signedUrl || '';
        } catch (signErr) {
          console.warn('Failed to sign URL for', filePath, signErr);
        }

        // مطابقة السجل في nurse_documents
        const record = recordedDocs.find(r => r.storage_path === filePath || r.document_type === matchedType);
        const reviewStatus = record?.review_status || 'pending'; // pending, approved, rejected
        const isPdf = fileName.toLowerCase().endsWith('.pdf') || (file.metadata?.mimetype === 'application/pdf');

        documentsList.push({
          id: record?.id || `${nurseUserId}-${fileName}`,
          nurse_id: nurseProfileId,
          nurse_user_id: nurseUserId,
          document_type: matchedType,
          document_title: meta.title,
          icon: meta.icon,
          is_required: meta.required,
          file_name: fileName,
          storage_path: filePath,
          signed_url: signedUrl,
          is_pdf: isPdf,
          size_bytes: file.metadata?.size || 0,
          created_at: file.created_at || record?.created_at || new Date().toISOString(),
          review_status: reviewStatus,
          status: reviewStatus,
          rejection_reason: record?.rejection_reason || '',
          is_unregistered: !record // ملف في Storage غير مسجل بعد في nurse_documents
        });

        processedTypes.add(matchedType);
      }

      // 5. فحص أي سجلات مسجلة في nurse_documents ولكن لم يتم العثور عليها في Storage list
      for (const record of recordedDocs) {
        if (record.storage_path && !handledStoragePaths.has(record.storage_path)) {
          let signedUrl = '';
          try {
            const { data: signedData } = await sb.storage
              .from('private-docs')
              .createSignedUrl(record.storage_path, 3600);
            signedUrl = signedData?.signedUrl || '';
          } catch (_) { }

          // تجاهل السجلات من أنواع محذوفة من الواجهة (experience / training)
          const meta = docTypeMeta[record.document_type];
          if (!meta) continue;
          const isPdf = record.storage_path.toLowerCase().endsWith('.pdf');

          documentsList.push({
            id: record.id,
            nurse_id: nurseProfileId,
            nurse_user_id: nurseUserId,
            document_type: record.document_type,
            document_title: meta.title,
            icon: meta.icon,
            is_required: meta.required,
            file_name: record.storage_path.split('/').pop() || record.document_type,
            storage_path: record.storage_path,
            signed_url: signedUrl,
            is_pdf: isPdf,
            size_bytes: 0,
            created_at: record.created_at,
            review_status: record.review_status || 'pending',
            status: record.review_status || 'pending',
            rejection_reason: record.rejection_reason || '',
            is_unregistered: false
          });

          processedTypes.add(record.document_type);
        }
      }

      // 6. إضافة مستندات غير مرفوعة (not_uploaded) للمستندات المطلوبة الناقصة
      for (const [type, meta] of Object.entries(docTypeMeta)) {
        if (!processedTypes.has(type)) {
          documentsList.push({
            id: `missing-${type}`,
            nurse_id: nurseProfileId,
            nurse_user_id: nurseUserId,
            document_type: type,
            document_title: meta.title,
            icon: meta.icon,
            is_required: meta.required,
            file_name: '',
            storage_path: '',
            signed_url: '',
            is_pdf: false,
            size_bytes: 0,
            created_at: null,
            review_status: 'not_uploaded',
            status: 'not_uploaded',
            rejection_reason: '',
            is_unregistered: false
          });
        }
      }

      // 7. حساب حالة الاستيفاء الإلزامية
      const mandatoryTypes = ['id_front', 'id_back', 'certificate'];
      const missingMandatory = [];
      const pendingMandatory = [];
      const rejectedMandatory = [];
      let readyForApproval = true;

      for (const mType of mandatoryTypes) {
        const item = documentsList.find(d => d.document_type === mType);
        if (!item || item.review_status === 'not_uploaded') {
          missingMandatory.push(docTypeMeta[mType].title);
          readyForApproval = false;
        } else if (item.review_status === 'rejected') {
          rejectedMandatory.push(docTypeMeta[mType].title);
          readyForApproval = false;
        } else if (item.review_status === 'pending') {
          pendingMandatory.push(docTypeMeta[mType].title);
          readyForApproval = false;
        }
      }

      return {
        documents: documentsList,
        summary: {
          readyForApproval,
          missingMandatory,
          pendingMandatory,
          rejectedMandatory,
          totalUploaded: documentsList.filter(d => d.review_status !== 'not_uploaded').length
        }
      };
    },

    // تحديث حالة مراجعة مستند معين (قبول أو رفض مع سبب الرفض)
    async adminUpdateDocumentStatus(nurseUserId, documentType, storagePath, newStatus, rejectionReason = '') {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!nurseUserId || !documentType) {
        throw new Error('معرف الممرض ونوع المستند مطلوبان.');
      }

      // 1. جلب معرف nurse_profiles.id
      const { data: np, error: npErr } = await sb
        .from('nurse_profiles')
        .select('id')
        .eq('user_id', nurseUserId)
        .maybeSingle();

      if (npErr) throw new Error('تعذر الوصول لملف الممرض: ' + npErr.message);
      const nurseProfileId = np?.id;
      if (!nurseProfileId) throw new Error('الملف المهني للممرض غير مسجل.');

      const updatePayload = {
        review_status: newStatus,
        rejection_reason: newStatus === 'rejected' ? rejectionReason : null,
        updated_at: new Date().toISOString()
      };

      // 2. البحث عن السجل القائم
      let query = sb
        .from('nurse_documents')
        .select('id')
        .eq('nurse_id', nurseProfileId);

      if (storagePath) {
        query = query.eq('storage_path', storagePath);
      } else {
        query = query.eq('document_type', documentType);
      }

      const { data: existing, error: selectErr } = await query.maybeSingle();
      if (selectErr) throw selectErr;

      // 3. تحديث السجل القائم أو إدراج سجل جديد للملف المرفوع
      if (existing?.id) {
        const { data: updatedData, error: updateErr } = await sb
          .from('nurse_documents')
          .update(updatePayload)
          .eq('id', existing.id)
          .select()
          .single();

        if (updateErr) {
          console.error('❌ adminUpdateDocumentStatus update error:', updateErr);
          throw new Error(`فشل تحديث حالة المستند: ${updateErr.message || updateErr.code}`);
        }
        return updatedData;
      } else {
        // إدراج سجل جديد لمستند موجود فعلياً في Storage
        if (!storagePath) {
          throw new Error('لا يمكن تسجيل المستند دون مسار تخزين فعلي.');
        }

        const insertPayload = {
          nurse_id: nurseProfileId,
          document_type: documentType,
          storage_path: storagePath,
          review_status: newStatus,
          rejection_reason: newStatus === 'rejected' ? rejectionReason : null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        };

        const { data: insertedData, error: insertErr } = await sb
          .from('nurse_documents')
          .insert(insertPayload)
          .select()
          .single();

        if (insertErr) {
          console.error('❌ adminUpdateDocumentStatus insert error:', insertErr);
          throw new Error(`فشل حفظ حالة المستند: ${insertErr.message || insertErr.code}`);
        }
        return insertedData;
      }
    },

    // ==========================================================
    // 7. نظام تقييم الممرضين بعد اكتمال الزيارة (Reviews & Ratings)
    // ==========================================================

    async createReview(bookingId, nurseId, rating, comment = '') {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const { data: { user }, error: authErr } = await sb.auth.getUser();
      if (authErr || !user) throw new Error('يجب تسجيل الدخول أولاً لإرسال التقييم.');

      const rNum = parseInt(rating, 10);
      if (isNaN(rNum) || rNum < 1 || rNum > 5) {
        throw new Error('يرجى اختيار تقييم بين 1 و 5 نجوم.');
      }

      // التأكد من أن الحجز مكتمل بالفعل
      const { data: booking, error: bErr } = await sb
        .from('bookings')
        .select('id, patient_id, nurse_id, status')
        .eq('id', bookingId)
        .single();

      if (bErr || !booking) {
        throw new Error('تعذّر العثور على بيانات الحجز المراد تقييمه.');
      }

      if (booking.status !== 'completed') {
        throw new Error('لا يمكن تقييم الزيارة إلا بعد اكتمالها بنجاح.');
      }

      if (booking.patient_id !== user.id) {
        throw new Error('لا يمكن التقييم إلا بواسطة المريض صاحب الحجز.');
      }

      const { data, error } = await sb
        .from('reviews')
        .insert({
          booking_id: bookingId,
          patient_id: user.id,
          nurse_id: booking.nurse_id,
          rating: rNum,
          comment: (comment || '').trim() || null
        })
        .select()
        .single();

      if (error) {
        if (error.code === '23505') {
          throw new Error('لقد قمت بتقييم هذه الزيارة مسبقاً.');
        }
        throw new Error(`فشل إرسال التقييم: ${error.message}`);
      }

      return data;
    },

    async getNurseReviews(nurseId) {
      const sb = getSupabase();
      if (!sb || !nurseId) return [];
      try {
        const { data, error } = await sb
          .from('reviews')
          .select('id, rating, comment, created_at, patient_id')
          .eq('nurse_id', nurseId)
          .order('created_at', { ascending: false });

        if (error) return [];
        return data || [];
      } catch (_) {
        return [];
      }
    },

    // ==========================================================
    // 8. إعدادات المنصة وطرق الدفع الرسمية (Platform Settings)
    // ==========================================================

    // جلب إعدادات الدفع العامة (payment_methods فقط - لا تُكشف إعدادات خاصة أخرى)
    async getPublicPlatformSettings() {
      const sb = getSupabase();
      if (!sb) return {};
      try {
        const { data, error } = await sb
          .from('platform_settings')
          .select('key, value')
          .eq('key', 'payment_methods')
          .maybeSingle();
        if (!error && data?.value) {
          try {
            localStorage.setItem('carenest_payment_methods_cache', JSON.stringify(data.value));
          } catch (_) {}
          return { payment_methods: data.value };
        }
      } catch (_) {}

      // استرجاع من الذاكرة المحلية كطبقة أمان في حال عدم وجود جلسة نشطة
      try {
        const cached = localStorage.getItem('carenest_payment_methods_cache');
        if (cached) {
          return { payment_methods: JSON.parse(cached) };
        }
      } catch (_) {}

      return {};
    },

    async getBookingPaymentDetails(bookingId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data, error } = await sb.rpc('get_booking_payment_details', { p_booking_id: bookingId });
      if (error) throw new Error(error.message || 'فشل استرجاع بيانات الدفع.');
      return data;
    },

    async adminGetPlatformSettings() {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data, error } = await sb
        .from('platform_settings')
        .select('*')
        .order('key');
      if (error) throw error;
      const map = {};
      (data || []).forEach(row => { map[row.key] = row.value; });
      return map;
    },

    async adminUpdatePlatformSetting(key, valueJson) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data: { user } } = await sb.auth.getUser();

      // 1. محاولة التحديث المباشر أولاً (UPDATE صريح)
      // يضمن تعديل updated_at وتشغيل تريجر AFTER UPDATE بنسبة 100%
      // ويتجنب تماماً خطأ duplicate key الناتج عن محاولة upsert بدون onConflict
      const { data: updateData, error: updateErr } = await sb
        .from('platform_settings')
        .update({
          value: valueJson,
          updated_at: new Date().toISOString(),
          updated_by: user?.id || null
        })
        .eq('key', key)
        .select();

      if (!updateErr && updateData && updateData.length > 0) {
        return updateData[0];
      }

      // 2. إذا لم يكن المفتاح موجوداً مسبقاً، ننشئه بـ upsert مع تحديد onConflict: 'key' صراحة
      const { data, error } = await sb
        .from('platform_settings')
        .upsert({
          key,
          value: valueJson,
          updated_at: new Date().toISOString(),
          updated_by: user?.id || null
        }, { onConflict: 'key' })
        .select()
        .maybeSingle();

      if (error) throw (updateErr || error);
      return data;
    },

    // ==========================================================
    // 9. إدارة المستندات الرسمية للمنصة (Official Platform Docs)
    // ==========================================================

    async adminUploadPlatformDocument(docType, file) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      if (!file) throw new Error('يرجى اختيار ملف PDF.');
      if (file.type !== 'application/pdf') throw new Error('المستند يجب أن يكون ملف PDF حصراً.');

      const cleanType = String(docType).trim();
      const storagePath = `platform_docs/${cleanType}.pdf`;

      // رفع الملف إلى سلة private-docs
      const { error: uploadErr } = await sb.storage
        .from('private-docs')
        .upload(storagePath, file, {
          cacheControl: '3600',
          upsert: true
        });

      if (uploadErr) throw new Error('فشل رفع المستند إلى التخزين: ' + uploadErr.message);

      // تحديث بيانات الإعداد
      const settingPayload = {
        file_path: storagePath,
        file_name: file.name,
        updated_at: new Date().toISOString()
      };

      await this.adminUpdatePlatformSetting(cleanType, settingPayload);
      return { success: true, path: storagePath };
    },

    async getPlatformDocumentSignedUrl(docType) {
      const sb = getSupabase();
      if (!sb) return null;
      try {
        const { data: setting } = await sb
          .from('platform_settings')
          .select('value')
          .eq('key', docType)
          .maybeSingle();

        const filePath = setting?.value?.file_path;
        if (!filePath) return null;

        const { data: signedData, error } = await sb.storage
          .from('private-docs')
          .createSignedUrl(filePath, 3600);

        if (error || !signedData?.signedUrl) return null;
        return {
          signedUrl: signedData.signedUrl,
          fileName: setting?.value?.file_name || 'document.pdf',
          updatedAt: setting?.value?.updated_at
        };
      } catch (_) {
        return null;
      }
    },

    // ==========================================================
    // 10. عقود الممرضين الرسمية والموقعة (Nurse Contracts)
    // ==========================================================

    async getNurseContractInfo(nurseUserId) {
      const sb = getSupabase();
      if (!sb || !nurseUserId) return null;
      try {
        const { data: np } = await sb
          .from('nurse_profiles')
          .select('id, contract_status, contract_rejection_reason, contract_reviewed_at')
          .eq('user_id', nurseUserId)
          .maybeSingle();

        const { data: contract } = await sb
          .from('nurse_contracts')
          .select('*')
          .eq('nurse_user_id', nurseUserId)
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();

        let signedUrl = null;
        if (contract?.storage_path) {
          const { data: sData } = await sb.storage
            .from('private-docs')
            .createSignedUrl(contract.storage_path, 3600);
          signedUrl = sData?.signedUrl || null;
        }

        return {
          status: np?.contract_status || 'not_uploaded',
          rejectionReason: np?.contract_rejection_reason || contract?.rejection_reason,
          reviewedAt: np?.contract_reviewed_at || contract?.reviewed_at,
          fileName: contract?.file_name,
          signedUrl,
          contractId: contract?.id
        };
      } catch (_) {
        return null;
      }
    },

    async submitSignedContract(file) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data: { user }, error: authErr } = await sb.auth.getUser();
      if (authErr || !user) throw new Error('يجب تسجيل الدخول أولاً.');
      if (!file) throw new Error('يرجى اختيار ملف العقد الموقع (PDF أو صورة).');

      const ext = (file.name.split('.').pop() || '').toLowerCase();
      if (!['pdf', 'jpg', 'jpeg', 'png', 'webp'].includes(ext)) {
        throw new Error('يرجى رفع ملف بصيغة PDF أو صورة (JPG, PNG, WEBP).');
      }

      const fileName = `contract_${Date.now()}.${ext}`;
      const storagePath = `${user.id}/contracts/${fileName}`;

      // 1. رفع الملف إلى Storage
      const { error: uploadErr } = await sb.storage
        .from('private-docs')
        .upload(storagePath, file, { cacheControl: '3600', upsert: false });

      if (uploadErr) throw new Error('فشل رفع ملف العقد: ' + uploadErr.message);

      // 2. استدعاء الدالة الذرية لتسجيل العقد
      const { data, error: rpcErr } = await sb.rpc('submit_signed_contract', {
        p_storage_path: storagePath,
        p_file_name: file.name
      });

      if (rpcErr) throw new Error(rpcErr.message || 'فشل تسجيل العقد.');
      if (data && data.success === false) throw new Error(data.error || 'فشل تسجيل العقد.');
      return data;
    },

    async adminGetAllNurseContracts(options = {}) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      let query = sb
        .from('nurse_contracts')
        .select(`
          id, nurse_id, nurse_user_id, storage_path, file_name, status,
          rejection_reason, reviewed_at, created_at,
          profiles:nurse_user_id(full_name, phone, email)
        `)
        .order('created_at', { ascending: false });

      if (options && options.status && options.status !== 'all') {
        query = query.eq('status', options.status);
      }

      const { data, error } = await query;
      if (error) throw error;
      const contracts = data || [];

      // توليد Signed URLs
      const results = [];
      for (const c of contracts) {
        let signedUrl = '';
        let signedUrlError = null;
        if (c.storage_path) {
          try {
            const { data: sData, error: sErr } = await sb.storage.from('private-docs').createSignedUrl(c.storage_path, 3600);
            if (sErr) {
              console.error('Error generating signed URL for contract:', c.storage_path, sErr);
              signedUrlError = sErr.message;
            } else {
              signedUrl = sData?.signedUrl || '';
            }
          } catch (err) {
            console.error('Exception generating signed URL for contract:', c.storage_path, err);
            signedUrlError = err.message;
          }
        }
        const fileName = c.file_name || (c.storage_path ? c.storage_path.split('/').pop() : '');
        results.push({
          ...c,
          nurse_name: c.profiles?.full_name || 'ممرض',
          nurse_phone: c.profiles?.phone || '-',
          nurse_email: c.profiles?.email || '-',
          nurse: c.profiles || {},
          storage_path: c.storage_path,
          file_path: c.storage_path,
          file_name: fileName,
          signed_url: signedUrl,
          signedUrl: signedUrl,
          signedUrlError: signedUrlError
        });
      }
      return results;
    },

    async adminReviewNurseContract(contractId, newStatus, rejectionReason = null) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data, error } = await sb.rpc('admin_review_nurse_contract', {
        p_contract_id: contractId,
        p_new_status: newStatus,
        p_rejection_reason: rejectionReason
      });
      if (error) throw new Error(error.message || 'فشل مراجعة العقد.');
      if (data && data.success === false) throw new Error(data.error || 'فشل مراجعة العقد.');
      return data;
    },

    // ==========================================================
    // 11. النظام المالي والمحفظة (Nurse Wallets & Finances)
    // ==========================================================

    async getNurseWallet(nurseUserId) {
      const sb = getSupabase();
      if (!sb || !nurseUserId) return null;
      try {
        const { data, error } = await sb
          .from('nurse_wallets')
          .select('*')
          .eq('nurse_user_id', nurseUserId)
          .maybeSingle();

        if (error || !data) {
          return {
            commission_debt: 0.00,
            pending_payouts: 0.00,
            total_paid_payouts: 0.00,
            total_settled_commissions: 0.00,
            total_visits_revenue: 0.00,
            total_commissions_due: 0.00,
            balance: 0.00
          };
        }
        return data;
      } catch (_) {
        return null;
      }
    },

    async getNurseFinancialTransactions(nurseUserId) {
      const sb = getSupabase();
      if (!sb || !nurseUserId) return [];
      try {
        const { data, error } = await sb
          .from('financial_transactions')
          .select('*')
          .eq('nurse_user_id', nurseUserId)
          .order('created_at', { ascending: false });

        if (error) return [];
        const txs = data || [];
        for (const t of txs) {
          if (t.receipt_path) {
            try {
              const { data: sData } = await sb.storage.from('private-docs').createSignedUrl(t.receipt_path, 3600);
              t.signed_receipt_url = sData?.signedUrl || null;
            } catch (_) { }
          }
        }
        return txs;
      } catch (_) {
        return [];
      }
    },
    async submitCommissionSettlement(amount, paymentMethod, storagePath, notes = '') {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const { data: { user }, error: authErr } = await sb.auth.getUser();

      if (authErr || !user) {
        throw new Error('يجب تسجيل الدخول أولاً.');
      }

      if (!storagePath || typeof storagePath !== 'string') {
        throw new Error('مسار إيصال السداد غير صالح.');
      }

      if (!storagePath.startsWith(`${user.id}/commission-settlements/`)) {
        throw new Error('مسار إيصال السداد غير مطابق لحسابك.');
      }

      const { data, error: rpcErr } = await sb.rpc('submit_commission_settlement', {
        p_amount: Number(amount),
        p_payment_method: paymentMethod,
        p_receipt_path: storagePath,
        p_notes: notes || null
      });

      if (rpcErr) {
        throw new Error(rpcErr.message || 'فشل تسجيل طلب السداد.');
      }

      if (data && data.success === false) {
        throw new Error(data.error || 'فشل تسجيل طلب السداد.');
      }

      return data;
    },

    async submitPatientPayment(bookingId, paymentMethod, file) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data: { user }, error: authErr } = await sb.auth.getUser();
      if (authErr || !user) throw new Error('يجب تسجيل الدخول أولاً.');

      // دعم التوافق: إذا تم تمرير مسار الملف الجاهز مباشرة بدلاً من كائن File
      let storagePath = null;
      let actualMethod = paymentMethod;

      if (typeof file === 'string' && file.startsWith('receipts/')) {
        // تم استدعاء الدالة بـ (bookingId, method, filePath)
        storagePath = file;
      } else if (typeof paymentMethod === 'string' && paymentMethod.startsWith('receipts/')) {
        // تم استدعاء الدالة بـ (bookingId, filePath, method)
        storagePath = paymentMethod;
        actualMethod = typeof file === 'string' ? file : 'vodafone_cash';
      }

      if (!storagePath) {
        if (!file || typeof file !== 'object') throw new Error('يرجى رفع صورة أو ملف إيصال التحويل.');

        const fileNameRaw = file.name || '';
        const ext = (fileNameRaw.split('.').pop() || '').toLowerCase();
        if (!['pdf', 'jpg', 'jpeg', 'png', 'webp'].includes(ext)) {
          throw new Error('يرجى رفع إيصال بصيغة صورة (JPG, PNG, WEBP) أو مستند PDF.');
        }

        // فحص حجم الملف (حد أقصى 5 ميجابايت)
        const maxBytes = 5 * 1024 * 1024;
        if (file.size && file.size > maxBytes) {
          throw new Error('حجم ملف الإيصال كبير جداً. الحد الأقصى المسموح به هو 5 ميجابايت.');
        }

        const mimeTypes = {
          'pdf': 'application/pdf',
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'png': 'image/png',
          'webp': 'image/webp'
        };
        const contentType = file.type || mimeTypes[ext] || 'application/octet-stream';

        const uniqueSuffix = Date.now() + '_' + Math.random().toString(36).substring(2, 7);
        const fileName = `patient_pay_${uniqueSuffix}.${ext}`;
        storagePath = `receipts/${bookingId}/${fileName}`;

        // رفع الملف باستخدام upsert: false للتوافق التام مع سياسة INSERT في Storage وتجنب خطأ RLS/CORS (Failed to fetch)
        const { error: uploadErr } = await sb.storage
          .from('private-docs')
          .upload(storagePath, file, {
            cacheControl: '3600',
            upsert: false,
            contentType: contentType
          });

        if (uploadErr) {
          console.error('❌ Supabase Storage upload error:', uploadErr);
          let detail = uploadErr.message || '';
          if (detail === 'Failed to fetch') {
            detail = 'تعذّر الاتصال بخادم التخزين السحابي. يرجى التحقق من اتصال الإنترنت أو تجربة رفع ملف بحجم أصغر.';
          }
          throw new Error('فشل رفع ملف الإيصال: ' + detail);
        }
      }

      // التحقق الصارم من أن المسار يخص المريض نفسه
      if (!storagePath.startsWith(`receipts/${bookingId}/`)) {
        throw new Error('مسار ملف الإيصال غير صالح أو لا ينتمي إلى حسابك.');
      }

      // استدعاء الدالة الذرية في قاعدة البيانات بعد التأكد التام من وجود الملف في Storage
      const { data, error: rpcErr } = await sb.rpc('submit_patient_payment', {
        p_booking_id: bookingId,
        p_payment_method: actualMethod,
        p_receipt_path: storagePath
      });

      if (rpcErr) throw new Error(rpcErr.message || 'فشل تسجيل إيصال الدفع.');
      if (data && data.success === false) throw new Error(data.error || 'فشل تسجيل إيصال الدفع.');
      return data;
    },

    async recordVisitCommission(bookingId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      // 1. استدعاء دالة تأكيد واحتساب العمولة الذرية بقاعدة البيانات
      try {
        const { data: rpcData, error: rpcErr } = await sb.rpc('record_visit_commission', {
          p_booking_id: bookingId
        });
        if (!rpcErr && rpcData && rpcData.success) {
          return rpcData;
        }
      } catch (_) { }

      // 2. التحقق من بيانات عمولة الحجز المسجلة تلقائياً عبر التريجر
      const { data, error } = await sb
        .from('bookings')
        .select('id, status, payment_method, commission_recorded, commission_rate, commission_amount, nurse_net_amount')
        .eq('id', bookingId)
        .maybeSingle();

      if (error) throw new Error(error.message || 'تعذر التحقق من عمولة الزيارة.');
      if (!data) throw new Error('الحجز غير موجود.');
      return data;
    },

    // ==========================================================
    // 12. لوحة الإدارة المالية الشاملة (Admin Financial Engine)
    // ==========================================================

    async adminGetFinancialStats() {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const [txRes, bookingsRes, walletsRes] = await Promise.all([
        sb.from('financial_transactions').select('type, amount, status'),
        sb.from('bookings').select('id, payment_method, payment_status, price, commission_amount, status'),
        sb.from('nurse_wallets').select('commission_debt, pending_payouts, total_paid_payouts, total_settled_commissions')
      ]);

      const txs = txRes.data || [];
      const bookings = bookingsRes.data || [];
      const wallets = walletsRes.data || [];

      const totalElectronicVerified = bookings
        .filter(b => ['vodafone_cash', 'instapay'].includes(b.payment_method) && b.payment_status === 'verified')
        .reduce((sum, b) => sum + Number(b.price || 0), 0);

      const totalElectronicPending = bookings
        .filter(b => ['vodafone_cash', 'instapay'].includes(b.payment_method) && b.payment_status === 'pending_review')
        .reduce((sum, b) => sum + Number(b.price || 0), 0);

      const totalElectronicRejected = bookings
        .filter(b => ['vodafone_cash', 'instapay'].includes(b.payment_method) && b.payment_status === 'rejected')
        .reduce((sum, b) => sum + Number(b.price || 0), 0);

      const totalPlatformCommissions = bookings
        .filter(b => b.status === 'completed')
        .reduce((sum, b) => sum + Number(b.commission_amount || 0), 0);

      const totalNurseDebts = wallets.reduce((sum, w) => sum + Number(w.commission_debt || 0), 0);
      const totalNursePendingPayouts = wallets.reduce((sum, w) => sum + Number(w.pending_payouts || 0), 0);
      const totalNursePaidPayouts = wallets.reduce((sum, w) => sum + Number(w.total_paid_payouts || 0), 0);
      const totalSettledCommissions = wallets.reduce((sum, w) => sum + Number(w.total_settled_commissions || 0), 0);

      const pendingPatientReceiptsCount = bookings
        .filter(b => b.payment_status === 'pending_review').length;

      const pendingSettlementsCount = txs
        .filter(t => t.type === 'commission_settlement' && t.status === 'pending_review').length;

      return {
        totalElectronicVerified,
        totalElectronicPending,
        totalElectronicRejected,
        totalPlatformCommissions,
        totalNurseDebts,
        totalNursePendingPayouts,
        totalNursePaidPayouts,
        totalSettledCommissions,
        pendingPatientReceiptsCount,
        pendingSettlementsCount
      };
    },

    async adminGetAllFinancialTransactions(filters = {}) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      let query = sb
        .from('financial_transactions')
        .select(`
          id, booking_id, nurse_id, nurse_user_id, patient_id, type, amount, status,
          payment_method, receipt_path, reviewed_at, rejection_reason, notes, created_at,
          patient:profiles!financial_transactions_patient_id_fkey(full_name, phone, email),
          nurse:profiles!financial_transactions_nurse_user_id_fkey(full_name, phone, email)
        `)
        .order('created_at', { ascending: false });

      if (filters.type && filters.type !== 'all') query = query.eq('type', filters.type);
      if (filters.status && filters.status !== 'all') query = query.eq('status', filters.status);
      if (filters.payment_method && filters.payment_method !== 'all') query = query.eq('payment_method', filters.payment_method);

      const { data, error } = await query;
      if (error) throw error;

      const txs = data || [];
      for (const t of txs) {
        if (t.receipt_path) {
          try {
            const cleanPath = String(t.receipt_path).replace(/^private-docs\//i, '');
            const { data: sData } = await sb.storage.from('private-docs').createSignedUrl(cleanPath, 3600);
            t.signed_receipt_url = sData?.signedUrl || null;
          } catch (_) { }
        }
      }
      return txs;
    },

    async adminGetAuditLogs(limit = 100) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const { data, error } = await sb
        .from('admin_audit_logs')
        .select(`
          id, admin_id, action, target_user_id, entity_type, entity_id, details, notes, created_at,
          admin:admin_id(full_name, email)
        `)
        .order('created_at', { ascending: false })
        .limit(limit);

      if (error) throw error;
      return data || [];
    },

    async adminApprovePatientPayment(bookingId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data, error } = await sb.rpc('admin_approve_patient_payment', { p_booking_id: bookingId });
      if (error) throw new Error(error.message || 'فشل تأكيد الدفع.');
      if (data && data.success === false) throw new Error(data.error || 'فشل تأكيد الدفع.');
      return data;
    },

    async adminRejectPatientPayment(bookingId, reason) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data, error } = await sb.rpc('admin_reject_patient_payment', {
        p_booking_id: bookingId,
        p_reason: reason
      });
      if (error) throw new Error(error.message || 'فشل رفض الدفع.');
      if (data && data.success === false) throw new Error(data.error || 'فشل رفض الدفع.');
      return data;
    },

    async adminApproveCommissionSettlement(transactionId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      let res = await sb.rpc('admin_approve_commission_settlement', { p_transaction_id: transactionId });
      if (res.error && res.error.message && res.error.message.includes('function')) {
        res = await sb.rpc('approve_commission_settlement', { p_transaction_id: transactionId });
      }
      if (res.error) throw new Error(res.error.message || 'فشل اعتماد السداد.');
      if (res.data === false || (res.data && res.data.success === false)) throw new Error(res.data?.error || 'فشل اعتماد السداد.');
      return res.data;
    },

    async adminRejectCommissionSettlement(transactionId, reason) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      let res = await sb.rpc('admin_reject_commission_settlement', {
        p_transaction_id: transactionId,
        p_reason: reason
      });
      if (res.error && res.error.message && res.error.message.includes('function')) {
        res = await sb.rpc('reject_commission_settlement', {
          p_transaction_id: transactionId,
          p_reason: reason
        });
      }
      if (res.error) throw new Error(res.error.message || 'فشل رفض السداد.');
      if (res.data === false || (res.data && res.data.success === false)) throw new Error(res.data?.error || 'فشل رفض السداد.');
      return res.data;
    },

    async adminRecordNursePayout(nurseId, amount, paymentMethod, receiptFile = null, notes = '') {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data: { user } } = await sb.auth.getUser();
      if (!user) throw new Error('يجب تسجيل الدخول كمسؤول أولاً.');

      let storagePath = null;
      if (receiptFile) {
        const ext = (receiptFile.name.split('.').pop() || '').toLowerCase();
        const fileName = `payout_${Date.now()}.${ext}`;
        // مسار التخزين يتوافق مع سياسة RLS لسلة private-docs: receipts/{auth.uid()}/...
        storagePath = `receipts/${user.id}/${fileName}`;

        const { error: uploadErr } = await sb.storage
          .from('private-docs')
          .upload(storagePath, receiptFile, { cacheControl: '3600', upsert: true });

        if (uploadErr) throw new Error('فشل رفع إيصال التحويل: ' + uploadErr.message);
      }

      const { data, error } = await sb.rpc('admin_record_nurse_payout', {
        p_nurse_id: nurseId,
        p_amount: Number(amount),
        p_payment_method: paymentMethod,
        p_receipt_path: storagePath,
        p_notes: notes || null
      });

      if (error) throw new Error(error.message || 'فشل تسجيل تحويل المستحقات.');
      if (data && data.success === false) throw new Error(data.error || 'فشل تسجيل تحويل المستحقات.');
      return data;
    },

    // ==========================================================
    // 13. نظام المحادثات المرتبطة بالحجز (Booking Messages)
    // ==========================================================

    async getBookingMessages(bookingId) {
      const sb = getSupabase();
      if (!sb || !bookingId) return [];
      try {
        const { data, error } = await sb
          .from('booking_messages')
          .select(`
            id, booking_id, sender_id, message, created_at,
            sender:profiles!booking_messages_sender_id_fkey(id, full_name, role, avatar_url)
          `)
          .eq('booking_id', bookingId)
          .order('created_at', { ascending: true });

        if (error) {
          // fallback: جلب بدون العلاقة
          const { data: d2, error: e2 } = await sb
            .from('booking_messages')
            .select('id, booking_id, sender_id, message, created_at')
            .eq('booking_id', bookingId)
            .order('created_at', { ascending: true });
          if (e2) return [];
          return (d2 || []).map(m => ({ ...m, sender: null }));
        }
        // توحيد حقل الاسم: نعطي الأولوية لـ sender.full_name ثم sender_name
        return (data || []).map(m => ({
          ...m,
          _senderName: (m.sender && m.sender.full_name) || m.sender_name || null
        }));
      } catch (_) {
        return [];
      }
    },

    async getAdminBookingMessages(bookingId) {
      // للأدمن: يجلب الرسائل لأي حجز (يعتمد على RLS التي تسمح للأدمن)
      return this.getBookingMessages(bookingId);
    },

    async getBookingsWithMessages() {
      const sb = getSupabase();
      if (!sb) return [];
      try {
        const { data, error } = await sb.rpc('get_bookings_with_messages');
        if (error) {
          console.warn('⚠️ getBookingsWithMessages error:', error.message);
          return [];
        }
        return data || [];
      } catch (err) {
        console.warn('⚠️ getBookingsWithMessages exception:', err);
        return [];
      }
    },

    async sendBookingMessage(bookingId, messageText) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      const { data: { user } } = await sb.auth.getUser();
      if (!user) throw new Error('يجب تسجيل الدخول لإرسال رسالة.');

      const cleanMsg = String(messageText || '').trim();
      if (!cleanMsg) throw new Error('الرسالة لا يمكن أن تكون فارغة.');

      const { data, error } = await sb
        .from('booking_messages')
        .insert({
          booking_id: bookingId,
          sender_id: user.id,
          message: cleanMsg
        })
        .select(`
          id, booking_id, sender_id, message, created_at,
          sender:sender_id(full_name, role, avatar_url)
        `)
        .single();

      if (error) throw error;
      return data;
    },

    // ==========================================================
    // Notifications
    // ==========================================================

    async getNotifications(limit = 20) {
      const sb = getSupabase();
      if (!sb) return [];

      try {
        const { data: { user } } = await sb.auth.getUser();
        if (!user) return [];

        const { data, error } = await sb
          .from('notifications')
          .select('id, title, message, type, link, is_read, created_at')
          .eq('user_id', user.id)
          .order('created_at', { ascending: false })
          .limit(Number(limit) || 20);

        if (error) {
          console.warn('⚠️ getNotifications error:', error.message);
          return [];
        }

        return data || [];
      } catch (err) {
        console.warn('⚠️ getNotifications exception:', err);
        return [];
      }
    },

    async markNotificationRead(notificationId) {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const { data: { user } } = await sb.auth.getUser();
      if (!user) throw new Error('يجب تسجيل الدخول.');

      const { error } = await sb
        .from('notifications')
        .update({ is_read: true })
        .eq('id', notificationId)
        .eq('user_id', user.id);

      if (error) throw error;
      return true;
    },

    async markAllNotificationsRead() {
      const sb = getSupabase();
      if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

      const { data: { user } } = await sb.auth.getUser();
      if (!user) throw new Error('يجب تسجيل الدخول.');

      const { error } = await sb
        .from('notifications')
        .update({ is_read: true })
        .eq('user_id', user.id)
        .eq('is_read', false);

      if (error) throw error;
      return true;
    },

    // ==========================================================
    // Contact Messages (نموذج التواصل في الصفحة الرئيسية)
    // ==========================================================

    async submitContactMessage({ senderName, senderPhone, senderEmail = '', subject = 'inquiry', message }) {
      const sb = getSupabase();

      if (!sb) {
        throw new Error('تعذّر الاتصال بقاعدة البيانات.');
      }

      const cleanName = String(senderName || '').trim();
      const cleanPhone = String(senderPhone || '').trim();
      const cleanEmail = String(senderEmail || '').trim();
      const cleanMsg = String(message || '').trim();

      if (!cleanName || cleanName.length < 3) {
        throw new Error('يرجى إدخال الاسم الكامل (3 أحرف على الأقل).');
      }

      if (!cleanPhone || cleanPhone.length < 10) {
        throw new Error('يرجى إدخال رقم هاتف صحيح.');
      }

      if (!cleanMsg || cleanMsg.length < 10) {
        throw new Error('يرجى كتابة رسالتك (10 أحرف على الأقل).');
      }

      if (cleanMsg.length > 2000) {
        throw new Error('الرسالة تجاوزت الحد الأقصى (2000 حرف).');
      }

      const payload = {
        sender_name: cleanName,
        sender_phone: cleanPhone,
        sender_email: cleanEmail || null,
        subject: subject || 'inquiry',
        message: cleanMsg,
        status: 'new'
      };

      const { data, error } = await sb
        .from('contact_messages')
        .insert(payload)
        .select('id')
        .single();

      if (error) {
        console.error('❌ submitContactMessage error:', error);
        throw new Error(`تعذّر إرسال رسالتك: ${error.message || 'خطأ غير معروف'}`);
      }

      return { success: true, id: data?.id };
    }
  };

  // ============================================================
  // Expose to window
  // ============================================================

  window.getSupabase = getSupabase;
  window.DB = DB;

})(typeof window !== 'undefined' ? window : this);
