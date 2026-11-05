// ============================================================
// رعايه | CareNest - Egypt Locations & Regional Data
// 27 Governorates & Administrative Centers
// ============================================================

(function (window) {
  'use strict';

  const EGYPT_DATA = {
    country: {
      code: 'EG',
      nameAr: 'جمهورية مصر العربية',
      nameEn: 'Egypt',
      defaultCenter: [30.0444, 31.2357],
      defaultZoom: 11,
      bounds: {
        minLat: 22.0,
        maxLat: 31.7,
        minLng: 25.0,
        maxLng: 36.9
      }
    },

    currency: {
      code: 'EGP',
      symbolAr: 'ج.م',
      nameAr: 'جنيه مصري',
      symbolEn: 'EGP',
      nameEn: 'Egyptian Pound'
    },

    // المحافظات المستهدفة حصرياً في منصة رعاية (5 محافظات)
    governorates: [
      {
        id: 'faiyum',
        nameAr: 'الفيوم',
        nameEn: 'Faiyum',
        cities: ['الفيوم', 'سنورس', 'إبشواي', 'طامية', 'إطسا', 'يوسف الصديق', 'الفيوم الجديدة']
      },
      {
        id: 'dakahlia',
        nameAr: 'الدقهلية',
        nameEn: 'Dakahlia',
        cities: [
          'المنصورة', 'طلخا', 'ميت غمر', 'السنبلاوين',
          'دكرنس', 'بلقاس', 'شربين', 'منية النصر', 'أجا'
        ]
      },
      {
        id: 'beheira',
        nameAr: 'البحيرة',
        nameEn: 'Beheira',
        cities: ['دمنهور', 'كفر الدوار', 'إيتاي البارود', 'كوم حمادة', 'أبو حمص', 'رشيد', 'وادي النطرون', 'الدلنجات']
      },
      {
        id: 'beni_suef',
        nameAr: 'بني سويف',
        nameEn: 'Beni Suef',
        cities: ['بني سويف', 'بني سويف الجديدة', 'الواسطى', 'ناصر', 'ببا', 'الفشن', 'إهناسيا', 'سمسطا']
      },
      {
        id: 'gharbia',
        nameAr: 'الغربية',
        nameEn: 'Gharbia',
        cities: ['طنطا', 'المحلة الكبرى', 'زفتى', 'كفر الزيات', 'سمنود', 'بسيون', 'قطور', 'السنطة']
      }
    ],

    // أرشيف المحافظات السابقة لضمان التوافق مع السجلات القديمة بقاعدة البيانات دون حذف
    legacyGovernorates: [
      { id: 'cairo', nameAr: 'القاهرة', nameEn: 'Cairo', cities: ['مدينة نصر', 'التجمع الخامس / القاهرة الجديدة', 'المعادي', 'مصر الجديدة', 'الزمالك', 'وسط البلد', 'شبرا', 'حلوان', 'المقطم', 'الرحاب', 'مدينتي', 'الشروق', 'عين شمس والزيتون', 'العباسية', 'المنيل', 'حدائق القبة'] },
      { id: 'giza', nameAr: 'الجيزة', nameEn: 'Giza', cities: ['الدقي', 'المهندسين', 'العجوزة', '6 أكتوبر', 'الشيخ زايد', 'الهرم', 'فيصل', 'العمرانية', 'الرماية وحدائق الأهرام', 'الحوامدية والبدرشين'] },
      { id: 'alexandria', nameAr: 'الإسكندرية', nameEn: 'Alexandria', cities: ['سموحة', 'سيدي جابر', 'لوران وجليم', 'رشدي وكفر عبده', 'ميامي وسيدي بشر', 'المنتزه والمندرة', 'محرم بك', 'العجمي والهانوفيل', 'برج العرب', 'الإبراهيمية والشاطبي'] },
      { id: 'sharqia', nameAr: 'الشرقية', nameEn: 'Sharqia', cities: ['الزقازيق', 'العاشر من رمضان', 'بلبيس', 'فاقوس', 'منيا القمح', 'أبو حماد', 'ديرب نجم', 'أبو كبير', 'الحسينية'] },
      { id: 'qalyubia', nameAr: 'القليوبية', nameEn: 'Qalyubia', cities: ['بنها', 'شبرا الخيمة', 'العبور', 'قليوب', 'طوخ', 'قها', 'الخانكة', 'شبين القناطر'] },
      { id: 'monufia', nameAr: 'المنوفية', nameEn: 'Monufia', cities: ['شبين الكوم', 'قويسنا', 'مدينة السادات', 'منوف', 'أشمون', 'تلا', 'بركة السبع', 'الشهداء'] },
      { id: 'damietta', nameAr: 'دمياط', nameEn: 'Damietta', cities: ['دمياط', 'رأس البر', 'دمياط الجديدة', 'فارسكور', 'الزرقا', 'كفر سعد', 'كفر البطيخ'] },
      { id: 'port_said', nameAr: 'بورسعيد', nameEn: 'Port Said', cities: ['حي الشرق', 'بورفؤاد', 'حي العرب', 'حي الزهور', 'حي الضواحي', 'حي المناخ', 'حي الجنوب'] },
      { id: 'ismailia', nameAr: 'الإسماعيلية', nameEn: 'Ismailia', cities: ['مدينة الإسماعيلية', 'فايد', 'القنطرة غرب', 'القنطرة شرق', 'التل الكبير', 'أبو صوير', 'القصاصين'] },
      { id: 'suez', nameAr: 'السويس', nameEn: 'Suez', cities: ['حي السويس', 'حي الأربعين', 'العين السخنة', 'حي فيصل', 'حي الجناين', 'عتاقة'] },
      { id: 'kafr_el_sheikh', nameAr: 'كفر الشيخ', nameEn: 'Kafr El Sheikh', cities: ['كفر الشيخ', 'دسوق', 'فوه', 'مطوبس', 'سيدي سالم', 'بلطيم', 'بيلا', 'قلين', 'الحامول'] },
      { id: 'minya', nameAr: 'المنيا', nameEn: 'Minya', cities: ['المنيا', 'المنيا الجديدة', 'ملوي', 'سمالوط', 'بني مزار', 'مغاغة', 'أبو قرقاص', 'مطاي', 'عدوة'] },
      { id: 'asyut', nameAr: 'أسيوط', nameEn: 'Asyut', cities: ['أسيوط', 'أسيوط الجديدة', 'ديروط', 'منفلوط', 'القوصية', 'الفتح', 'أبنوب', 'أبو تيج', 'صدفا', 'الغنايم'] },
      { id: 'sohag', nameAr: 'سوهاج', nameEn: 'Sohag', cities: ['سوهاج', 'سوهاج الجديدة', 'طهطا', 'أخميم', 'جرجا', 'المراغة', 'البلينا', 'طما', 'المنشأة', 'دار السلام'] },
      { id: 'qena', nameAr: 'قنا', nameEn: 'Qena', cities: ['قنا', 'قنا الجديدة', 'نجع حمادي', 'قوص', 'دشنا', 'أبو تشت', 'قفط', 'نقادة', 'فرشوط'] },
      { id: 'luxor', nameAr: 'الأقصر', nameEn: 'Luxor', cities: ['الأقصر', 'طيبة الجديدة', 'إسنا', 'أرمنت', 'القرنة', 'البياضية', 'الزينية'] },
      { id: 'aswan', nameAr: 'أسوان', nameEn: 'Aswan', cities: ['أسوان', 'أسوان الجديدة', 'كوم أمبو', 'إدفو', 'دراو', 'نصر النوبة', 'أبو سمبل'] },
      { id: 'red_sea', nameAr: 'البحر الأحمر', nameEn: 'Red Sea', cities: ['الغردقة', 'الجونة', 'سفاجا', 'مرسى علم', 'القصير', 'رأس غارب', 'الشلاتين', 'حلايب'] },
      { id: 'south_sinai', nameAr: 'جنوب سيناء', nameEn: 'South Sinai', cities: ['شرم الشيخ', 'دهب', 'نويبع', 'طابا', 'طور سيناء', 'رأس سدر', 'سانت كاترين', 'أبو زنيمة', 'أبو رديس'] },
      { id: 'north_sinai', nameAr: 'شمال سيناء', nameEn: 'North Sinai', cities: ['العريش', 'بئر العبد', 'الشيخ زويد', 'رفح', 'نخل', 'الحسنة'] },
      { id: 'matrouh', nameAr: 'مطروح', nameEn: 'Matrouh', cities: ['مرسى مطروح', 'العلمين والساحل الشمالي', 'الحمام', 'الضبعة', 'سيوة', 'النجيلة', 'سيدي براني', 'السلوم'] },
      { id: 'new_valley', nameAr: 'الوادي الجديد', nameEn: 'New Valley', cities: ['الخارجة', 'الداخلة', 'الفرافرة', 'باريس', 'بلاط'] }
    ]
  };

  const EgyptLocations = {
    data: EGYPT_DATA,

    getGovernorates() {
      return EGYPT_DATA.governorates;
    },

    getGovernorateNames(lang) {
      const language = lang || (typeof window !== 'undefined' && window.i18n && window.i18n.currentLang) || 'ar';
      return EGYPT_DATA.governorates.map(function (gov) {
        return language === 'en' ? gov.nameEn : gov.nameAr;
      });
    },

    getCities(governorateName) {
      if (!governorateName) return [];

      const raw = String(governorateName).trim();
      const lower = raw.toLowerCase();

      // 1. البحث في المحافظات المستهدفة أولاً
      let governorate = EGYPT_DATA.governorates.find(function (item) {
        return item.nameAr === raw ||
          item.id.toLowerCase() === lower ||
          item.nameEn.toLowerCase() === lower;
      });

      // 2. البحث في الأرشيف القديم للتوافق في حال وجود بيانات سابقة للمستخدم
      if (!governorate && Array.isArray(EGYPT_DATA.legacyGovernorates)) {
        governorate = EGYPT_DATA.legacyGovernorates.find(function (item) {
          return item.nameAr === raw ||
            item.id.toLowerCase() === lower ||
            item.nameEn.toLowerCase() === lower;
        });
      }

      return governorate ? [...governorate.cities] : [];
    },

    formatPrice(amount, lang) {
      const num = Number(amount) || 0;
      const language = lang || (typeof window !== 'undefined' && window.i18n && window.i18n.currentLang) || 'ar';
      return language === 'en' ? `${num} EGP` : `${num} ج.م`;
    },

    formatEGP(amount, lang) {
      return this.formatPrice(amount, lang);
    },

    formatCurrencyFull(amount, lang) {
      const num = Number(amount) || 0;
      const language = lang || (typeof window !== 'undefined' && window.i18n && window.i18n.currentLang) || 'ar';
      return language === 'en' ? `${num} Egyptian Pounds` : `${num} جنيه مصري`;
    },

    validateEgyptianPhone(phone) {
      if (!phone) return false;
      const cleaned = String(phone).replace(/[\s\-()]/g, '');
      return /^(?:01[0125]\d{8}|\+201[0125]\d{8}|201[0125]\d{8}|00201[0125]\d{8})$/.test(cleaned);
    },

    isValidEgyptianMobile(phone) {
      return this.validateEgyptianPhone(phone);
    },

    formatEgyptianPhone(phone) {
      if (!phone) return '';
      let cleaned = String(phone).replace(/[\s\-()]/g, '');
      if (cleaned.startsWith('+20')) {
        cleaned = cleaned.substring(3);
      } else if (cleaned.startsWith('0020')) {
        cleaned = cleaned.substring(4);
      } else if (cleaned.startsWith('20') && cleaned.length === 12) {
        cleaned = cleaned.substring(2);
      }
      if (cleaned.startsWith('0')) {
        cleaned = cleaned.substring(1);
      }
      return '+20 ' + cleaned;
    },

    isWithinEgypt(lat, lng) {
      if (lat == null || lng == null) return false;
      const latitude = Number(lat);
      const longitude = Number(lng);
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
        return false;
      }
      const bounds = EGYPT_DATA.country.bounds;
      return latitude >= bounds.minLat &&
        latitude <= bounds.maxLat &&
        longitude >= bounds.minLng &&
        longitude <= bounds.maxLng;
    },

    populateGovernorateSelect(selectElement, selectedValue, defaultPlaceholder, lang) {
      if (!selectElement) return;

      const language = lang || (typeof window !== 'undefined' && window.i18n && window.i18n.currentLang) || 'ar';
      const selected = selectedValue ? String(selectedValue).trim() : '';
      const placeholder = defaultPlaceholder !== undefined
        ? defaultPlaceholder
        : (language === 'en' ? 'Select Governorate' : 'اختر المحافظة');

      selectElement.innerHTML = '';

      if (placeholder !== null && placeholder !== '') {
        const defaultOpt = document.createElement('option');
        defaultOpt.value = '';
        defaultOpt.textContent = placeholder.startsWith('--') ? placeholder : `-- ${placeholder} --`;
        selectElement.appendChild(defaultOpt);
      }

      EGYPT_DATA.governorates.forEach(function (gov) {
        const option = document.createElement('option');
        // We set value to Arabic name for consistent database storage
        option.value = gov.nameAr;
        option.textContent = language === 'en' ? gov.nameEn : gov.nameAr;

        const isMatch = selected && (
          selected === gov.nameAr ||
          selected.toLowerCase() === gov.nameEn.toLowerCase() ||
          selected.toLowerCase() === gov.id.toLowerCase()
        );
        if (isMatch) {
          option.selected = true;
        }

        selectElement.appendChild(option);
      });
    },

    populateCitySelect(citySelectElement, governorateName, selectedCity, defaultPlaceholder, lang) {
      if (!citySelectElement) return;

      const language = lang || (typeof window !== 'undefined' && window.i18n && window.i18n.currentLang) || 'ar';
      const selected = selectedCity ? String(selectedCity).trim() : '';

      citySelectElement.innerHTML = '';

      if (!governorateName) {
        citySelectElement.disabled = true;
        const disabledPlaceholder = defaultPlaceholder !== undefined
          ? defaultPlaceholder
          : (language === 'en' ? '-- Select governorate first --' : '-- اختر المحافظة أولاً --');
        const defaultOpt = document.createElement('option');
        defaultOpt.value = '';
        defaultOpt.textContent = disabledPlaceholder;
        citySelectElement.appendChild(defaultOpt);
        return;
      }

      const cities = this.getCities(governorateName);

      if (cities.length === 0) {
        citySelectElement.disabled = true;
        const noCitiesPlaceholder = language === 'en' ? '-- No cities available --' : '-- لا توجد مدن متاحة --';
        const defaultOpt = document.createElement('option');
        defaultOpt.value = '';
        defaultOpt.textContent = noCitiesPlaceholder;
        citySelectElement.appendChild(defaultOpt);
        return;
      }

      citySelectElement.disabled = false;

      const placeholder = defaultPlaceholder !== undefined
        ? defaultPlaceholder
        : (language === 'en' ? 'Select City / District' : 'اختر المدينة أو المركز');

      if (placeholder !== null && placeholder !== '') {
        const defaultOpt = document.createElement('option');
        defaultOpt.value = '';
        defaultOpt.textContent = placeholder.startsWith('--') ? placeholder : `-- ${placeholder} --`;
        citySelectElement.appendChild(defaultOpt);
      }

      cities.forEach(function (city) {
        const option = document.createElement('option');
        option.value = city;
        option.textContent = city;
        if (selected && selected === city) {
          option.selected = true;
        }
        citySelectElement.appendChild(option);
      });
    },

    /**
     * Helper to bind a governorate select and a city select together automatically.
     */
    bindGovernorateAndCity(govSelect, citySelect, options = {}) {
      if (!govSelect || !citySelect) return;

      const self = this;
      const initialGov = options.initialGovernorate || '';
      const initialCity = options.initialCity || '';
      const govPlaceholder = options.govPlaceholder;
      const cityPlaceholder = options.cityPlaceholder;
      const getLang = () => options.lang || (typeof window !== 'undefined' && window.i18n && window.i18n.currentLang) || 'ar';

      // 1. Populate Governorates
      self.populateGovernorateSelect(govSelect, initialGov, govPlaceholder, getLang());

      // 2. Populate Cities based on initial governorate
      const currentGovVal = govSelect.value || initialGov;
      self.populateCitySelect(citySelect, currentGovVal, initialCity, cityPlaceholder, getLang());

      // 3. Bind change event
      const onGovChange = function () {
        const chosenGov = govSelect.value;
        self.populateCitySelect(citySelect, chosenGov, '', cityPlaceholder, getLang());
        if (typeof options.onChange === 'function') {
          options.onChange(chosenGov);
        }
      };

      govSelect.removeEventListener('change', govSelect._egyptLocHandler || (()=>{}));
      govSelect._egyptLocHandler = onGovChange;
      govSelect.addEventListener('change', onGovChange);
    }
  };

  window.EgyptLocations = EgyptLocations;

})(typeof window !== 'undefined' ? window : globalThis);
