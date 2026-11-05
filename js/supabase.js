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

      if (!sb) return null;

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
    // Bookings
    // يعتمد bookings.nurse_id على nurse_profiles.id
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

      // يجب أن يكون هذا هو معرّف nurse_profiles.id
      const nurseId =
        bookingData.nurse_profile_id ||
        bookingData.nurse_id;

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

      const duration = Number(
        bookingData.duration_hours || 1
      );

      if (
        !Number.isFinite(duration) ||
        duration <= 0 ||
        duration > 24
      ) {
        throw new Error(
          'مدة الزيارة غير صحيحة.'
        );
      }

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
        throw new Error(
          'وقت الزيارة غير صحيح.'
        );
      }

      const endTotal =
        hours * 3600 +
        minutes * 60 +
        seconds +
        duration * 3600;

      if (endTotal > 86400) {
        throw new Error(
          'وقت انتهاء الزيارة يتجاوز نهاية اليوم.'
        );
      }

      const pad = (number) =>
        String(number).padStart(2, '0');

      const endTime = [
        pad(Math.floor(endTotal / 3600) % 24),
        pad(Math.floor((endTotal % 3600) / 60)),
        pad(endTotal % 60)
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

      // التحقق من تحديد المحافظة والمدينة بدون افتراضات تلقائية (M4)
      const selectedGov = (bookingData.governorate || '').trim();
      const selectedCity = (bookingData.city || '').trim();

      if (!selectedGov) {
        throw new Error('يرجى اختيار المحافظة لإتمام الحجز.');
      }

      // فحص تعارض المواعيد للممرض (Schedule conflict check)
      try {
        const { data: conflicts } = await sb
          .from('bookings')
          .select('id, start_time, end_time, status')
          .eq('nurse_id', nurseId)
          .eq('visit_date', visitDate)
          .in('status', ['pending', 'accepted', 'in_progress']);

        if (conflicts && conflicts.length > 0) {
          const hasConflict = conflicts.some((c) => {
            const cStart = c.start_time || '';
            const cEnd = c.end_time || '';
            return startTime < cEnd && endTime > cStart;
          });
          if (hasConflict) {
            throw new Error('الممرض لديه زيارة أخرى مجدولة في نفس هذا التوقيت، يرجى اختيار موعد آخر.');
          }
        }
      } catch (confErr) {
        if (confErr.message && confErr.message.includes('الممرض لديه زيارة')) {
          throw confErr;
        }
      }

      // تجهيز عنوان المريض مع تضمين إحداثيات GPS إن توفرت لضمان حفظها ومشاركتها مع الممرض
      const rawAddress = (bookingData.patient_address || '').trim();
      const hasCoords = bookingData.latitude != null && bookingData.longitude != null &&
        !isNaN(Number(bookingData.latitude)) && !isNaN(Number(bookingData.longitude));
      
      const formattedAddress = hasCoords && !rawAddress.includes('[GPS:')
        ? `${rawAddress} [GPS: ${Number(bookingData.latitude).toFixed(6)}, ${Number(bookingData.longitude).toFixed(6)}]`
        : rawAddress;

      const payload = {
        patient_id: user.id,
        nurse_id: nurseId,
        service_type: serviceType,
        service_name: serviceType,
        visit_date: visitDate,
        start_time: startTime,
        end_time: endTime,
        duration_hours: Number(bookingData.duration_hours || 1),
        total_price: submittedPrice,
        price: submittedPrice,
        status: 'pending',
        currency: 'EGP',
        country: 'Egypt',
        governorate: selectedGov,
        city: selectedCity,
        patient_name: bookingData.patient_name || '',
        patient_phone: bookingData.patient_phone || '',
        patient_address: formattedAddress,
        patient_notes:
          bookingData.patient_notes ||
          bookingData.notes ||
          null,
        notes:
          bookingData.patient_notes ||
          bookingData.notes ||
          null,
        latitude: hasCoords ? Number(bookingData.latitude) : null,
        longitude: hasCoords ? Number(bookingData.longitude) : null
      };

      let {
        data,
        error
      } = await sb
        .from('bookings')
        .insert(payload)
        .select()
        .single();

      // إذا حدث خطأ PostgREST بسبب عدم وجود أعمدة إضافية في جدول bookings، نرسل الحقول الأساسية
      if (error && (error.code === 'PGRST204' || (error.message && error.message.includes('column')))) {
        console.warn('⚠️ إعادة المحاولة بالحقول الأساسية لتوافق Schema:', error.message);
        const fallbackPayload = {
          patient_id: user.id,
          nurse_id: nurseId,
          service_type: serviceType,
          visit_date: visitDate,
          start_time: startTime,
          end_time: endTime,
          patient_address: formattedAddress,
          patient_notes:
            bookingData.patient_notes ||
            bookingData.notes ||
            null,
          price: submittedPrice
        };
        const retry = await sb.from('bookings').insert(fallbackPayload).select().single();
        data = retry.data;
        error = retry.error;
      }

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

      // 2. جلب بيانات الممرضين المرتبطين بالحجوزات (حيث bookings.nurse_id = nurse_profiles.id)
      const nurseIds = [...new Set(rawBookings.map(b => b.nurse_id).filter(Boolean))];
      const nurseMap = {};

      if (nurseIds.length > 0) {
        try {
          // استعلام nurse_profiles
          const { data: nProfiles, error: npError } = await sb
            .from('nurse_profiles')
            .select('id, user_id, specialization, governorate, city')
            .in('id', nurseIds);

          if (!npError && nProfiles) {
            const userIds = [...new Set(nProfiles.map(np => np.user_id).filter(Boolean))];
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
              nurseMap[np.id] = {
                id: np.id,
                user_id: np.user_id,
                full_name: u.full_name || 'ممرض معتمد',
                phone: u.phone || '',
                avatar_url: u.avatar_url || null,
                specialization: np.specialization || ''
              };
            });
          }

          // فحص احتياطي لأي حجز قديم قد يحمل profiles.id مباشرة
          const missingNurseIds = nurseIds.filter(id => !nurseMap[id]);
          if (missingNurseIds.length > 0) {
            const { data: directProfiles } = await sb
              .from('profiles')
              .select('id, full_name, phone, avatar_url')
              .in('id', missingNurseIds);

            if (directProfiles) {
              directProfiles.forEach(p => {
                nurseMap[p.id] = {
                  id: p.id,
                  user_id: p.id,
                  full_name: p.full_name || 'ممرض معتمد',
                  phone: p.phone || '',
                  avatar_url: p.avatar_url || null,
                  specialization: ''
                };
              });
            }
          }
        } catch (nErr) {
          console.warn('⚠️ تعذّر استرجاع تفاصيل الممرض للحجز:', nErr);
        }
      }

      return rawBookings.map((b) => {
        const nurseData = nurseMap[b.nurse_id] || { full_name: 'ممرض معتمد' };
        const priceNum = Number(b.price ?? 0);

        return {
          ...b,
          service_name: b.service_type || b.service_name || 'زيارة تمريضية',
          price: priceNum,
          total_price: priceNum,
          visit_time: b.start_time || b.visit_time || '',
          notes: b.patient_notes || b.notes || '',
          patient_address: b.patient_address || '',
          nurse: nurseData
        };
      });
    },

    // ==========================================================
    // Nurse Bookings
    // ==========================================================

    async getNurseBookings(nurseId, status = null) {
      const sb = getSupabase();

      if (!sb) return [];

      if (!nurseId) {
        throw new Error('معرّف الممرض غير موجود.');
      }

      // 1. تحويل معرّف المستخدم profiles.id إلى nurse_profiles.id لأن bookings.nurse_id = nurse_profiles.id
      let targetNurseProfileId = null;

      try {
        const { data: nurseProfile, error: npErr } = await sb
          .from('nurse_profiles')
          .select('id')
          .eq('user_id', nurseId)
          .maybeSingle();

        if (npErr) {
          console.warn('⚠️ بحث nurse_profiles:', npErr.message);
        } else if (nurseProfile?.id) {
          targetNurseProfileId = nurseProfile.id;
        }
      } catch (lookupErr) {
        console.warn('⚠️ تعذّر البحث عن ملف الممرض:', lookupErr);
      }

      // 2. استعلام جدول bookings مباشرة وبشكل مستقل لتفادي مشاكل الـ embedding
      let query = sb
        .from('bookings')
        .select('*')
        .order('visit_date', { ascending: true });

      // إذا وجدنا nurse_profiles.id نبحث به مع تضمين user_id احتياطياً للحجوزات القديمة
      if (targetNurseProfileId) {
        query = query.or(`nurse_id.eq.${targetNurseProfileId},nurse_id.eq.${nurseId}`);
      } else {
        query = query.eq('nurse_id', nurseId);
      }

      if (status && status !== 'all') {
        query = query.eq('status', status);
      }

      const { data, error } = await query;

      if (error) {
        console.error('❌ getNurseBookings error:', error);
        throw new Error(`فشل جلب حجوزات الممرض: ${error.message || error.code}`);
      }

      const rawBookings = data || [];

      // 3. جلب بيانات المرضى عبر دالة get_nurse_patient_profiles RPC الآمنة
      const patientBookingsMap = {};

      try {
        const { data: rpcData, error: rpcErr } = await sb.rpc('get_nurse_patient_profiles');

        if (rpcErr) {
          console.warn('⚠️ get_nurse_patient_profiles RPC warning:', rpcErr.message || rpcErr);
        } else if (rpcData && Array.isArray(rpcData)) {
          rpcData.forEach((row) => {
            if (row && row.booking_id) {
              patientBookingsMap[row.booking_id] = row;
            }
          });
        }
      } catch (rpcCatchErr) {
        console.warn('⚠️ Exception calling get_nurse_patient_profiles RPC:', rpcCatchErr);
      }

      return rawBookings.map((b) => {
        const patientData = patientBookingsMap[b.id] || {};

        // الحماية H3: إخفاء بيانات المريض الحساسة (الهاتف والعنوان والإحداثيات) قبل قبول الطلب
        const isAcceptedOrBeyond = ['accepted', 'in_progress', 'completed'].includes(b.status);

        // استخراج إحداثيات GPS إن وجدت (فقط بعد قبول الحجز)
        let lat = null;
        let lng = null;
        if (isAcceptedOrBeyond) {
          lat = b.latitude != null ? Number(b.latitude) : null;
          lng = b.longitude != null ? Number(b.longitude) : null;
          if ((lat == null || isNaN(lat)) || (lng == null || isNaN(lng))) {
            const fullText = `${patientData.patient_address || b.patient_address || ''} ${b.patient_notes || ''}`;
            const gpsMatch = fullText.match(/\[GPS:\s*(-?\d+\.?\d*),\s*(-?\d+\.?\d*)\]/i);
            if (gpsMatch) {
              lat = parseFloat(gpsMatch[1]);
              lng = parseFloat(gpsMatch[2]);
            }
          }
        }

        const priceNum = Number(b.price ?? 0);
        const patientFullName = patientData.full_name || b.patient_name || 'مريض مسجل';
        const displayPhone = isAcceptedOrBeyond ? (patientData.phone || b.patient_phone || '') : '';
        const rawAddress = patientData.patient_address || b.patient_address || '';
        const gov = b.governorate || patientData.governorate || '';
        const city = b.city || patientData.city || '';
        const displayAddress = isAcceptedOrBeyond
          ? rawAddress
          : (gov && city ? `${gov} - ${city}` : 'يظهر العنوان بعد قبول الطلب');

        return {
          ...b,
          patient_name: patientFullName,
          patient_phone: displayPhone,
          patient_address: displayAddress,
          governorate: gov,
          city: city,
          service_name: b.service_type || b.service_name || 'زيارة تمريضية',
          duration_hours: Number(b.duration_hours || 1),
          price: priceNum,
          total_price: priceNum,
          visit_time: b.start_time || b.visit_time || '',
          notes: b.patient_notes || b.notes || '',
          latitude: lat,
          longitude: lng,
          is_patient_masked: !isAcceptedOrBeyond,
          patient: isAcceptedOrBeyond ? patientData : { full_name: patientFullName }
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

      // 4. فحص الصلاحيات بناءً على دور المستخدم
      let userRole = currentUser.user_metadata?.role || null;
      if (!userRole) {
        const { data: prof } = await sb.from('profiles').select('role').eq('id', currentUser.id).maybeSingle();
        userRole = prof?.role || 'patient';
      }

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
        if (updateErr.message && updateErr.message.includes('انتقال حالة الحجز غير مسموح')) {
          throw new Error('انتقال حالة الحجز غير مسموح وفقاً لقيود أمان النظام.');
        }
        throw new Error(`فشل تحديث الحجز في قاعدة البيانات: ${updateErr.message || updateErr.code}`);
      }

      if (!updatedRows || updatedRows.length === 0) {
        // فحص ما إذا كان التحديث تم فعلاً في قاعدة البيانات لكن RLS حجب قراءة النتيجة
        const { data: verifyRow } = await sb
          .from('bookings')
          .select('id, status')
          .eq('id', cleanBookingId)
          .maybeSingle();

        if (verifyRow && verifyRow.status === cleanStatus) {
          return { ...existingBooking, status: cleanStatus, updated_at: new Date().toISOString() };
        }

        console.error('❌ updateBookingStatus: 0 rows affected for bookingId:', cleanBookingId);
        throw new Error('لم يتم تحديث الحجز: تم رفض التعديل بواسطة سياسة أمان قاعدة البيانات (RLS) لعدم تطابق شروط الصلاحية.');
      }

      return updatedRows[0];
    },

    // ==========================================================
    // Visit Confirmation System (Codes & Verification)
    // ==========================================================

    /**
     * جلب كود التحقق الخاص بالمريض (بدء أو إنهاء الزيارة)
     * يستدعي دالة RPC: get_patient_visit_code
     * ملاحظة أمنية: لا يتم طباعة الكود في console نهائياً
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

      // التحقق من وجود جلسة مستخدم نشطة
      const { data: authData, error: authErr } = await sb.auth.getUser();
      if (authErr || !authData?.user) {
        throw new Error('انتهت جلسة تسجيل الدخول. يرجى تسجيل الدخول مجدداً للمتابعة.');
      }

      const { data, error } = await sb.rpc('get_patient_visit_code', {
        p_booking_id: cleanBookingId
      });

      if (error) {
        console.error('getPatientVisitCode error:', error.message || error);
        throw new Error(error.message || 'فشل جلب كود تأكيد الزيارة من الخادم.');
      }

      let parsed = data;
      if (typeof parsed === 'string') {
        try {
          parsed = JSON.parse(parsed);
        } catch (_) {}
      }

      if (!parsed) {
        throw new Error('لم يتم استلام استجابة صالحة من خدمة كود الزيارة.');
      }

      if (parsed.available === false) {
        return {
          available: false,
          error: parsed.error || null,
          reason: parsed.reason || parsed.error || 'الكود غير متوفر حالياً.',
          is_locked: Boolean(parsed.is_locked),
          is_used: Boolean(parsed.is_used),
          expired: Boolean(parsed.expired),
          code_type: parsed.code_type || null
        };
      }

      return {
        available: true,
        code: String(parsed.code),
        code_type: parsed.code_type,
        expires_at: parsed.expires_at || null
      };
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
          } catch (_) {}
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
        } catch (_) {}
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
      const [nursesRes, patientsRes, bookingsRes] = await Promise.all([
        sb.from('nurse_profiles').select('id, verified, is_active', { count: 'exact' }),
        sb.from('profiles').select('id', { count: 'exact' }).eq('role', 'patient'),
        sb.from('bookings').select('id, status, price', { count: 'exact' })
      ]);

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

      const totalNurses = nursesRes.count ?? nursesList.length;
      const approvedNurses = nursesList.filter(n => n.verified === true && n.is_active !== false).length;
      const suspendedNurses = nursesList.filter(n => n.verified === true && n.is_active === false).length;
      const pendingNurses = nursesList.filter(n => n.verified === false).length;

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
      } catch (_) {}

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
          } catch (_) {}

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
    }
  };

  // ============================================================
  // Expose to window
  // ============================================================

  window.getSupabase = getSupabase;
  window.DB = DB;

})(typeof window !== 'undefined' ? window : this);