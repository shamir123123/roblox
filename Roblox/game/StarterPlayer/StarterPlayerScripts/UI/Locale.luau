--!strict
-- UI.Locale
-- Player-chosen UI language. Roblox's own auto-localization follows the
-- player's ACCOUNT locale and can't be pointed at a language they picked in a
-- menu, so this does the swap itself.
--
-- How: every translatable string is indexed by a normalised form (spaces
-- stripped, lowercased) in EVERY language, so a label can be re-translated from
-- whatever it currently reads. On the first swap a label keeps its original
-- text in an attribute, which is what makes switching back to English exact --
-- headers are letter-spaced ("G R A P H I C S") and that spelling can't be
-- reconstructed from the key.
--
-- Text with no entry -- money, city names, the clock, player names -- has no
-- index hit and is left alone. That is the whole safety property: dynamic text
-- can never be clobbered by a language change.
--
-- Adding a string: add one row to STRINGS. No controller changes, ever.

local Players = game:GetService("Players")

local Locale = {}

export type Option = { label: string, value: string }

-- The seven most-spoken languages by total speakers. Labels stay in the native
-- script on purpose: someone who can't read the current UI language still has
-- to find their own in this list.
local LANGUAGES: { Option } = {
	{ label = "English", value = "en" },
	{ label = "中文", value = "zh" },
	{ label = "हिन्दी", value = "hi" },
	{ label = "Español", value = "es" },
	{ label = "Français", value = "fr" },
	{ label = "العربية", value = "ar" },
	{ label = "বাংলা", value = "bn" },
	{ label = "Deutsch", value = "de" },
}

-- English is the key. Covers the settings page end to end -- every category,
-- row, dropdown option and button on it.
local STRINGS: { [string]: { [string]: string } } = {
	["Control Room"] = { zh = "控制室", hi = "नियंत्रण कक्ष", es = "Sala de control", fr = "Salle de contrôle", ar = "غرفة التحكم", bn = "নিয়ন্ত্রণ কক্ষ" },
	["Graphics"] = { zh = "图形", hi = "ग्राफ़िक्स", es = "Gráficos", fr = "Graphismes", ar = "الرسومات", bn = "গ্রাফিক্স" },
	["Gameplay"] = { zh = "玩法", hi = "गेमप्ले", es = "Juego", fr = "Jeu", ar = "اللعب", bn = "গেমপ্লে" },
	["Audio"] = { zh = "音频", hi = "ऑडियो", es = "Audio", fr = "Audio", ar = "الصوت", bn = "অডিও" },
	["Interface"] = { zh = "界面", hi = "इंटरफ़ेस", es = "Interfaz", fr = "Interface", ar = "الواجهة", bn = "ইন্টারফেস" },
	["Input"] = { zh = "输入", hi = "इनपुट", es = "Controles", fr = "Commandes", ar = "التحكم", bn = "ইনপুট" },
	["General"] = { zh = "通用", hi = "सामान्य", es = "General", fr = "Général", ar = "عام", bn = "সাধারণ" },
	["Language"] = { zh = "语言", hi = "भाषा", es = "Idioma", fr = "Langue", ar = "اللغة", bn = "ভাষা" },

	["Quality preset"] = { zh = "画质预设", hi = "क्वालिटी प्रीसेट", es = "Preajuste de calidad", fr = "Préréglage de qualité", ar = "إعداد الجودة", bn = "কোয়ালিটি প্রিসেট" },
	["Detail"] = { zh = "细节", hi = "विवरण", es = "Detalle", fr = "Détail", ar = "التفاصيل", bn = "বিস্তারিত" },
	["Shadow quality"] = { zh = "阴影质量", hi = "छाया गुणवत्ता", es = "Calidad de sombras", fr = "Qualité des ombres", ar = "جودة الظلال", bn = "ছায়ার মান" },
	["Draw distance"] = { zh = "视野距离", hi = "ड्रॉ डिस्टेंस", es = "Distancia de dibujado", fr = "Distance d'affichage", ar = "مسافة العرض", bn = "দৃশ্য দূরত্ব" },
	["Effects"] = { zh = "特效", hi = "प्रभाव", es = "Efectos", fr = "Effets", ar = "التأثيرات", bn = "ইফেক্ট" },
	["Bloom"] = { zh = "泛光", hi = "ब्लूम", es = "Resplandor", fr = "Éclat", ar = "التوهج", bn = "ব্লুম" },
	["Sun rays"] = { zh = "阳光光束", hi = "सूर्य किरणें", es = "Rayos de sol", fr = "Rayons du soleil", ar = "أشعة الشمس", bn = "সূর্যরশ্মি" },
	["Depth of field"] = { zh = "景深", hi = "डेप्थ ऑफ़ फ़ील्ड", es = "Profundidad de campo", fr = "Profondeur de champ", ar = "عمق المجال", bn = "ডেপথ অফ ফিল্ড" },
	["Atmosphere haze"] = { zh = "大气雾霾", hi = "वायुमंडलीय धुंध", es = "Bruma atmosférica", fr = "Brume atmosphérique", ar = "ضباب الغلاف الجوي", bn = "বায়ুমণ্ডলীয় কুয়াশা" },
	["Water"] = { zh = "水面", hi = "पानी", es = "Agua", fr = "Eau", ar = "الماء", bn = "জল" },
	["Water waves"] = { zh = "水波", hi = "पानी की लहरें", es = "Olas del agua", fr = "Vagues", ar = "أمواج الماء", bn = "জলের ঢেউ" },
	["Water reflections"] = { zh = "水面反射", hi = "पानी का प्रतिबिंब", es = "Reflejos del agua", fr = "Reflets de l'eau", ar = "انعكاسات الماء", bn = "জলের প্রতিফলন" },
	["Water clarity"] = { zh = "水体清澈度", hi = "पानी की स्वच्छता", es = "Claridad del agua", fr = "Clarté de l'eau", ar = "صفاء الماء", bn = "জলের স্বচ্ছতা" },
	["Effect strength"] = { zh = "特效强度", hi = "प्रभाव की तीव्रता", es = "Intensidad de efectos", fr = "Intensité des effets", ar = "قوة التأثير", bn = "ইফেক্টের মাত্রা" },
	["Bloom intensity"] = { zh = "泛光强度", hi = "ब्लूम तीव्रता", es = "Intensidad del resplandor", fr = "Intensité de l'éclat", ar = "شدة التوهج", bn = "ব্লুমের মাত্রা" },
	["Sun ray intensity"] = { zh = "光束强度", hi = "किरण तीव्रता", es = "Intensidad de los rayos", fr = "Intensité des rayons", ar = "شدة الأشعة", bn = "রশ্মির মাত্রা" },
	["Haze density"] = { zh = "雾霾浓度", hi = "धुंध घनत्व", es = "Densidad de la bruma", fr = "Densité de la brume", ar = "كثافة الضباب", bn = "কুয়াশার ঘনত্ব" },
	["Color grading"] = { zh = "调色", hi = "कलर ग्रेडिंग", es = "Corrección de color", fr = "Étalonnage", ar = "تدرج الألوان", bn = "কালার গ্রেডিং" },
	["Color grade"] = { zh = "启用调色", hi = "कलर ग्रेड", es = "Graduación de color", fr = "Correction colorimétrique", ar = "تصحيح الألوان", bn = "কালার গ্রেড" },
	["Saturation"] = { zh = "饱和度", hi = "संतृप्ति", es = "Saturación", fr = "Saturation", ar = "التشبع", bn = "স্যাচুরেশন" },
	["Contrast"] = { zh = "对比度", hi = "कंट्रास्ट", es = "Contraste", fr = "Contraste", ar = "التباين", bn = "কনট্রাস্ট" },
	["Brightness"] = { zh = "亮度", hi = "चमक", es = "Brillo", fr = "Luminosité", ar = "السطوع", bn = "উজ্জ্বলতা" },
	["Exposure"] = { zh = "曝光", hi = "एक्सपोज़र", es = "Exposición", fr = "Exposition", ar = "التعريض", bn = "এক্সপোজার" },
	["Correct each colour"] = { zh = "单色校正", hi = "हर रंग सुधारें", es = "Corregir cada color", fr = "Corriger chaque couleur", ar = "تصحيح كل لون", bn = "প্রতিটি রঙ সংশোধন" },
	["Red"] = { zh = "红色", hi = "लाल", es = "Rojo", fr = "Rouge", ar = "أحمر", bn = "লাল" },
	["Green"] = { zh = "绿色", hi = "हरा", es = "Verde", fr = "Vert", ar = "أخضر", bn = "সবুজ" },
	["Blue"] = { zh = "蓝色", hi = "नीला", es = "Azul", fr = "Bleu", ar = "أزرق", bn = "নীল" },

	["Autosave"] = { zh = "自动保存", hi = "ऑटो सेव", es = "Autoguardado", fr = "Sauvegarde auto", ar = "حفظ تلقائي", bn = "অটোসেভ" },
	["Autosave interval"] = { zh = "自动保存间隔", hi = "ऑटो सेव अंतराल", es = "Intervalo de autoguardado", fr = "Intervalle de sauvegarde", ar = "فترة الحفظ التلقائي", bn = "অটোসেভের বিরতি" },
	["Day/night cycle"] = { zh = "昼夜循环", hi = "दिन/रात चक्र", es = "Ciclo día/noche", fr = "Cycle jour/nuit", ar = "دورة الليل والنهار", bn = "দিন/রাত চক্র" },
	["Start paused"] = { zh = "开始时暂停", hi = "रुका हुआ शुरू करें", es = "Empezar en pausa", fr = "Démarrer en pause", ar = "البدء موقتًا", bn = "বিরতি দিয়ে শুরু" },
	["Show FPS"] = { zh = "显示帧率", hi = "FPS दिखाएँ", es = "Mostrar FPS", fr = "Afficher les FPS", ar = "إظهار الإطارات", bn = "FPS দেখান" },
	["Every minute"] = { zh = "每分钟", hi = "हर मिनट", es = "Cada minuto", fr = "Chaque minute", ar = "كل دقيقة", bn = "প্রতি মিনিটে" },
	["Every 2 minutes"] = { zh = "每 2 分钟", hi = "हर 2 मिनट", es = "Cada 2 minutos", fr = "Toutes les 2 minutes", ar = "كل دقيقتين", bn = "প্রতি ২ মিনিটে" },
	["Every 5 minutes"] = { zh = "每 5 分钟", hi = "हर 5 मिनट", es = "Cada 5 minutos", fr = "Toutes les 5 minutes", ar = "كل 5 دقائق", bn = "প্রতি ৫ মিনিটে" },
	["Every 10 minutes"] = { zh = "每 10 分钟", hi = "हर 10 मिनट", es = "Cada 10 minutos", fr = "Toutes les 10 minutes", ar = "كل 10 دقائق", bn = "প্রতি ১০ মিনিটে" },
	["Every 15 minutes"] = { zh = "每 15 分钟", hi = "हर 15 मिनट", es = "Cada 15 minutos", fr = "Toutes les 15 minutes", ar = "كل 15 دقيقة", bn = "প্রতি ১৫ মিনিটে" },
	["Every 30 minutes"] = { zh = "每 30 分钟", hi = "हर 30 मिनट", es = "Cada 30 minutos", fr = "Toutes les 30 minutes", ar = "كل 30 دقيقة", bn = "প্রতি ৩০ মিনিটে" },
	["Every hour"] = { zh = "每小时", hi = "हर घंटा", es = "Cada hora", fr = "Toutes les heures", ar = "كل ساعة", bn = "প্রতি ঘণ্টায়" },

	["Master volume"] = { zh = "主音量", hi = "मुख्य वॉल्यूम", es = "Volumen general", fr = "Volume général", ar = "مستوى الصوت الرئيسي", bn = "প্রধান ভলিউম" },
	["Music volume"] = { zh = "音乐音量", hi = "संगीत वॉल्यूम", es = "Volumen de música", fr = "Volume de la musique", ar = "مستوى الموسيقى", bn = "সঙ্গীতের ভলিউম" },
	["Sound effects"] = { zh = "音效", hi = "ध्वनि प्रभाव", es = "Efectos de sonido", fr = "Effets sonores", ar = "المؤثرات الصوتية", bn = "সাউন্ড ইফেক্ট" },
	["Ambience"] = { zh = "环境音", hi = "परिवेश ध्वनि", es = "Ambiente", fr = "Ambiance", ar = "الأجواء", bn = "পরিবেশ শব্দ" },

	["Layout"] = { zh = "布局", hi = "लेआउट", es = "Diseño", fr = "Disposition", ar = "التخطيط", bn = "লেআউট" },
	["HUD scale"] = { zh = "界面缩放", hi = "HUD आकार", es = "Escala del HUD", fr = "Échelle de l'interface", ar = "حجم الواجهة", bn = "HUD স্কেল" },
	["UI transparency"] = { zh = "界面透明度", hi = "UI पारदर्शिता", es = "Transparencia de la interfaz", fr = "Transparence de l'interface", ar = "شفافية الواجهة", bn = "UI স্বচ্ছতা" },
	["Frosted glass"] = { zh = "磨砂玻璃", hi = "फ्रॉस्टेड ग्लास", es = "Cristal esmerilado", fr = "Verre dépoli", ar = "زجاج ضبابي", bn = "ফ্রস্টেড গ্লাস" },
	["Prompts"] = { zh = "提示", hi = "संकेत", es = "Avisos", fr = "Invites", ar = "التنبيهات", bn = "প্রম্পট" },
	["Tooltips"] = { zh = "工具提示", hi = "टूलटिप", es = "Descripciones", fr = "Infobulles", ar = "تلميحات", bn = "টুলটিপ" },
	["Notifications"] = { zh = "通知", hi = "सूचनाएँ", es = "Notificaciones", fr = "Notifications", ar = "الإشعارات", bn = "বিজ্ঞপ্তি" },
	["Units"] = { zh = "单位", hi = "इकाइयाँ", es = "Unidades", fr = "Unités", ar = "الوحدات", bn = "একক" },
	["Clock format"] = { zh = "时间格式", hi = "घड़ी प्रारूप", es = "Formato de hora", fr = "Format de l'heure", ar = "تنسيق الوقت", bn = "ঘড়ির ফরম্যাট" },
	["Distance"] = { zh = "距离", hi = "दूरी", es = "Distancia", fr = "Distance", ar = "المسافة", bn = "দূরত্ব" },
	["12 hour"] = { zh = "12 小时制", hi = "12 घंटे", es = "12 horas", fr = "12 heures", ar = "12 ساعة", bn = "১২ ঘণ্টা" },
	["24 hour"] = { zh = "24 小时制", hi = "24 घंटे", es = "24 horas", fr = "24 heures", ar = "24 ساعة", bn = "২৪ ঘণ্টা" },
	["Metric (km)"] = { zh = "公制 (km)", hi = "मीट्रिक (km)", es = "Métrico (km)", fr = "Métrique (km)", ar = "متري (km)", bn = "মেট্রিক (km)" },
	["Imperial (mi)"] = { zh = "英制 (mi)", hi = "इंपीरियल (mi)", es = "Imperial (mi)", fr = "Impérial (mi)", ar = "إمبراطوري (mi)", bn = "ইম্পেরিয়াল (mi)" },
	["Studs"] = { zh = "单位格", hi = "स्टड्स", es = "Studs", fr = "Studs", ar = "ستادز", bn = "স্টাডস" },

	["Camera"] = { zh = "摄像机", hi = "कैमरा", es = "Cámara", fr = "Caméra", ar = "الكاميرا", bn = "ক্যামেরা" },
	["Camera forward"] = { zh = "摄像机前进", hi = "कैमरा आगे", es = "Cámara adelante", fr = "Caméra avant", ar = "الكاميرا للأمام", bn = "ক্যামেরা সামনে" },
	["Camera back"] = { zh = "摄像机后退", hi = "कैमरा पीछे", es = "Cámara atrás", fr = "Caméra arrière", ar = "الكاميرا للخلف", bn = "ক্যামেরা পিছনে" },
	["Camera left"] = { zh = "摄像机左移", hi = "कैमरा बाएँ", es = "Cámara izquierda", fr = "Caméra à gauche", ar = "الكاميرا لليسار", bn = "ক্যামেরা বামে" },
	["Camera right"] = { zh = "摄像机右移", hi = "कैमरा दाएँ", es = "Cámara derecha", fr = "Caméra à droite", ar = "الكاميرا لليمين", bn = "ক্যামেরা ডানে" },
	["Rotate left"] = { zh = "向左旋转", hi = "बाएँ घुमाएँ", es = "Girar a la izquierda", fr = "Pivoter à gauche", ar = "تدوير لليسار", bn = "বামে ঘোরান" },
	["Rotate right"] = { zh = "向右旋转", hi = "दाएँ घुमाएँ", es = "Girar a la derecha", fr = "Pivoter à droite", ar = "تدوير لليمين", bn = "ডানে ঘোরান" },
	["Camera up"] = { zh = "摄像机上升", hi = "कैमरा ऊपर", es = "Cámara arriba", fr = "Caméra vers le haut", ar = "الكاميرا للأعلى", bn = "ক্যামেরা উপরে" },
	["Camera down"] = { zh = "摄像机下降", hi = "कैमरा नीचे", es = "Cámara abajo", fr = "Caméra vers le bas", ar = "الكاميرا للأسفل", bn = "ক্যামেরা নিচে" },
	["Camera feel"] = { zh = "摄像机手感", hi = "कैमरा फील", es = "Sensación de cámara", fr = "Comportement caméra", ar = "إحساس الكاميرا", bn = "ক্যামেরার অনুভূতি" },
	["Camera speed"] = { zh = "摄像机速度", hi = "कैमरा गति", es = "Velocidad de cámara", fr = "Vitesse de caméra", ar = "سرعة الكاميرا", bn = "ক্যামেরার গতি" },
	["Rotation speed"] = { zh = "旋转速度", hi = "घुमाव गति", es = "Velocidad de giro", fr = "Vitesse de rotation", ar = "سرعة الدوران", bn = "ঘোরানোর গতি" },
	["Zoom speed"] = { zh = "缩放速度", hi = "ज़ूम गति", es = "Velocidad de zoom", fr = "Vitesse de zoom", ar = "سرعة التقريب", bn = "জুমের গতি" },
	["Mouse sensitivity"] = { zh = "鼠标灵敏度", hi = "माउस संवेदनशीलता", es = "Sensibilidad del ratón", fr = "Sensibilité de la souris", ar = "حساسية الفأرة", bn = "মাউস সংবেদনশীলতা" },
	["Edge scrolling"] = { zh = "边缘滚动", hi = "एज स्क्रॉलिंग", es = "Desplazamiento en bordes", fr = "Défilement des bords", ar = "التمرير من الحافة", bn = "এজ স্ক্রলিং" },
	["Reset to defaults"] = { zh = "恢复默认", hi = "डिफ़ॉल्ट पर रीसेट", es = "Restablecer valores", fr = "Réinitialiser", ar = "استعادة الافتراضي", bn = "ডিফল্টে রিসেট" },
	["PRESS KEY"] = { zh = "按下按键", hi = "कोई कुंजी दबाएँ", es = "PULSA UNA TECLA", fr = "APPUYEZ SUR UNE TOUCHE", ar = "اضغط مفتاحًا", bn = "কী চাপুন" },

	["On"] = { zh = "开", hi = "चालू", es = "Sí", fr = "Oui", ar = "تشغيل", bn = "চালু" },
	["Off"] = { zh = "关", hi = "बंद", es = "No", fr = "Non", ar = "إيقاف", bn = "বন্ধ" },
	["Hard"] = { zh = "硬", hi = "हार्ड", es = "Duras", fr = "Dures", ar = "حادة", bn = "হার্ড" },
	["Soft"] = { zh = "柔和", hi = "सॉफ़्ट", es = "Suaves", fr = "Douces", ar = "ناعمة", bn = "সফট" },
	["Simple"] = { zh = "简单", hi = "सरल", es = "Simple", fr = "Simple", ar = "بسيط", bn = "সরল" },
	["Advanced"] = { zh = "高级", hi = "उन्नत", es = "Avanzado", fr = "Avancé", ar = "متقدم", bn = "উন্নত" },
	["Low"] = { zh = "低", hi = "कम", es = "Bajo", fr = "Faible", ar = "منخفض", bn = "নিম্ন" },
	["Medium"] = { zh = "中", hi = "मध्यम", es = "Medio", fr = "Moyen", ar = "متوسط", bn = "মাঝারি" },
	["High"] = { zh = "高", hi = "उच्च", es = "Alto", fr = "Élevé", ar = "عالٍ", bn = "উচ্চ" },
	["Ultra"] = { zh = "极高", hi = "अल्ट्रा", es = "Ultra", fr = "Ultra", ar = "فائق", bn = "আল্ট্রা" },
	["Custom"] = { zh = "自定义", hi = "कस्टम", es = "Personalizado", fr = "Personnalisé", ar = "مخصص", bn = "কাস্টম" },
	["Before"] = { zh = "之前", hi = "पहले", es = "Antes", fr = "Avant", ar = "قبل", bn = "আগে" },
	["After"] = { zh = "之后", hi = "बाद", es = "Después", fr = "Après", ar = "بعد", bn = "পরে" },

	-- ---------------------------------------------------------- main menu --
	["PLAY"] = { zh = "开始游戏", hi = "खेलें", es = "JUGAR", fr = "JOUER", ar = "العب", bn = "খেলুন" },
	["CONTINUE"] = { zh = "继续游戏", hi = "जारी रखें", es = "CONTINUAR", fr = "CONTINUER", ar = "متابعة", bn = "চালিয়ে যান" },
	["NEW GAME"] = { zh = "新游戏", hi = "नया गेम", es = "NUEVA PARTIDA", fr = "NOUVELLE PARTIE", ar = "لعبة جديدة", bn = "নতুন গেম" },
	["LOAD GAME"] = { zh = "载入游戏", hi = "गेम लोड करें", es = "CARGAR PARTIDA", fr = "CHARGER UNE PARTIE", ar = "تحميل لعبة", bn = "গেম লোড করুন" },
	["LOADING GAME"] = { zh = "正在载入", hi = "गेम लोड हो रहा है", es = "CARGANDO PARTIDA", fr = "CHARGEMENT", ar = "جارٍ التحميل", bn = "গেম লোড হচ্ছে" },
	["SETTINGS"] = { zh = "设置", hi = "सेटिंग्स", es = "AJUSTES", fr = "PARAMÈTRES", ar = "الإعدادات", bn = "সেটিংস" },
	["Settings"] = { zh = "设置", hi = "सेटिंग्स", es = "Ajustes", fr = "Paramètres", ar = "الإعدادات", bn = "সেটিংস" },
	["Game Settings"] = { zh = "游戏设置", hi = "गेम सेटिंग्स", es = "Ajustes del juego", fr = "Paramètres du jeu", ar = "إعدادات اللعبة", bn = "গেম সেটিংস" },
	["CREDITS"] = { zh = "制作名单", hi = "क्रेडिट्स", es = "CRÉDITOS", fr = "CRÉDITS", ar = "المساهمون", bn = "কৃতজ্ঞতা" },
	["Exit"] = { zh = "退出", hi = "बाहर निकलें", es = "Salir", fr = "Quitter", ar = "خروج", bn = "প্রস্থান" },
	["MENU"] = { zh = "菜单", hi = "मेनू", es = "MENÚ", fr = "MENU", ar = "القائمة", bn = "মেনু" },
	["Main Menu"] = { zh = "主菜单", hi = "मुख्य मेनू", es = "Menú principal", fr = "Menu principal", ar = "القائمة الرئيسية", bn = "প্রধান মেনু" },
	["Return to Main Menu"] = { zh = "返回主菜单", hi = "मुख्य मेनू पर लौटें", es = "Volver al menú principal", fr = "Retour au menu principal", ar = "العودة إلى القائمة الرئيسية", bn = "প্রধান মেনুতে ফিরুন" },
	["Return to Menu"] = { zh = "返回菜单", hi = "मेनू पर लौटें", es = "Volver al menú", fr = "Retour au menu", ar = "العودة إلى القائمة", bn = "মেনুতে ফিরুন" },
	["Resume"] = { zh = "继续", hi = "फिर से शुरू", es = "Reanudar", fr = "Reprendre", ar = "استئناف", bn = "পুনরায় শুরু" },
	["CONTENT HUB"] = { zh = "内容中心", hi = "कंटेंट हब", es = "CENTRO DE CONTENIDO", fr = "CENTRE DE CONTENU", ar = "مركز المحتوى", bn = "কন্টেন্ট হাব" },
	["Content Hub"] = { zh = "内容中心", hi = "कंटेंट हब", es = "Centro de contenido", fr = "Centre de contenu", ar = "مركز المحتوى", bn = "কন্টেন্ট হাব" },
	["MY CREATIONS"] = { zh = "我的作品", hi = "मेरी रचनाएँ", es = "MIS CREACIONES", fr = "MES CRÉATIONS", ar = "إبداعاتي", bn = "আমার সৃষ্টি" },
	["My Creations"] = { zh = "我的作品", hi = "मेरी रचनाएँ", es = "Mis creaciones", fr = "Mes créations", ar = "إبداعاتي", bn = "আমার সৃষ্টি" },
	["CREATION EDITOR"] = { zh = "创作编辑器", hi = "क्रिएशन एडिटर", es = "EDITOR DE CREACIONES", fr = "ÉDITEUR DE CRÉATIONS", ar = "محرر الإبداع", bn = "ক্রিয়েশন এডিটর" },
	["EDITOR"] = { zh = "编辑器", hi = "एडिटर", es = "EDITOR", fr = "ÉDITEUR", ar = "المحرر", bn = "এডিটর" },
	["Open Editor"] = { zh = "打开编辑器", hi = "एडिटर खोलें", es = "Abrir editor", fr = "Ouvrir l'éditeur", ar = "فتح المحرر", bn = "এডিটর খুলুন" },
	["UPDATE LOG"] = { zh = "更新日志", hi = "अपडेट लॉग", es = "REGISTRO DE CAMBIOS", fr = "JOURNAL DES MISES À JOUR", ar = "سجل التحديثات", bn = "আপডেট লগ" },
	["UPDATE LOGS"] = { zh = "更新日志", hi = "अपडेट लॉग्स", es = "REGISTROS DE CAMBIOS", fr = "JOURNAUX DE MISES À JOUR", ar = "سجلات التحديث", bn = "আপডেট লগ" },
	["DASHBOARDS"] = { zh = "数据面板", hi = "डैशबोर्ड", es = "PANELES", fr = "TABLEAUX DE BORD", ar = "لوحات المعلومات", bn = "ড্যাশবোর্ড" },
	["City Dashboard"] = { zh = "城市面板", hi = "सिटी डैशबोर्ड", es = "Panel de la ciudad", fr = "Tableau de bord de la ville", ar = "لوحة المدينة", bn = "সিটি ড্যাশবোর্ড" },
	["Info & dashboards"] = { zh = "信息与面板", hi = "जानकारी और डैशबोर्ड", es = "Info y paneles", fr = "Infos et tableaux de bord", ar = "المعلومات واللوحات", bn = "তথ্য ও ড্যাশবোর্ড" },
	["Info Panel"] = { zh = "信息面板", hi = "जानकारी पैनल", es = "Panel de información", fr = "Panneau d'informations", ar = "لوحة المعلومات", bn = "তথ্য প্যানেল" },
	["SANDBOX"] = { zh = "沙盒", hi = "सैंडबॉक्स", es = "SANDBOX", fr = "BAC À SABLE", ar = "وضع حر", bn = "স্যান্ডবক্স" },
	["SANDBOX MODE"] = { zh = "沙盒模式", hi = "सैंडबॉक्स मोड", es = "MODO SANDBOX", fr = "MODE BAC À SABLE", ar = "الوضع الحر", bn = "স্যান্ডবক্স মোড" },

	-- ------------------------------------------------- cities: save & load --
	["FOUND CITY"] = { zh = "建立城市", hi = "शहर बसाएँ", es = "FUNDAR CIUDAD", fr = "FONDER UNE VILLE", ar = "تأسيس مدينة", bn = "শহর প্রতিষ্ঠা" },
	["SELECT YOUR MAP"] = { zh = "选择地图", hi = "अपना मैप चुनें", es = "ELIGE TU MAPA", fr = "CHOISISSEZ VOTRE CARTE", ar = "اختر خريطتك", bn = "আপনার ম্যাপ বাছুন" },
	["SEED"] = { zh = "种子", hi = "सीड", es = "SEMILLA", fr = "GRAINE", ar = "بذرة", bn = "সিড" },
	["REROLL SEED"] = { zh = "重新生成", hi = "सीड बदलें", es = "NUEVA SEMILLA", fr = "NOUVELLE GRAINE", ar = "بذرة جديدة", bn = "নতুন সিড" },
	["STEP 1 / 2"] = { zh = "第 1 / 2 步", hi = "चरण 1 / 2", es = "PASO 1 / 2", fr = "ÉTAPE 1 / 2", ar = "الخطوة 1 / 2", bn = "ধাপ ১ / ২" },
	["SAVE CITY"] = { zh = "保存城市", hi = "शहर सेव करें", es = "GUARDAR CIUDAD", fr = "SAUVEGARDER LA VILLE", ar = "حفظ المدينة", bn = "শহর সেভ করুন" },
	["LOAD CITY"] = { zh = "载入城市", hi = "शहर लोड करें", es = "CARGAR CIUDAD", fr = "CHARGER LA VILLE", ar = "تحميل المدينة", bn = "শহর লোড করুন" },
	["DELETE CITY"] = { zh = "删除城市", hi = "शहर हटाएँ", es = "ELIMINAR CIUDAD", fr = "SUPPRIMER LA VILLE", ar = "حذف المدينة", bn = "শহর মুছুন" },
	["RENAME CITY"] = { zh = "重命名城市", hi = "शहर का नाम बदलें", es = "RENOMBRAR CIUDAD", fr = "RENOMMER LA VILLE", ar = "إعادة تسمية المدينة", bn = "শহরের নাম বদলান" },
	["RENAME"] = { zh = "重命名", hi = "नाम बदलें", es = "RENOMBRAR", fr = "RENOMMER", ar = "إعادة تسمية", bn = "নাম বদলান" },
	["DELETE"] = { zh = "删除", hi = "हटाएँ", es = "ELIMINAR", fr = "SUPPRIMER", ar = "حذف", bn = "মুছুন" },
	["Delete"] = { zh = "删除", hi = "हटाएँ", es = "Eliminar", fr = "Supprimer", ar = "حذف", bn = "মুছুন" },
	["Save"] = { zh = "保存", hi = "सेव करें", es = "Guardar", fr = "Sauvegarder", ar = "حفظ", bn = "সেভ করুন" },
	["Save City"] = { zh = "保存城市", hi = "शहर सेव करें", es = "Guardar ciudad", fr = "Sauvegarder la ville", ar = "حفظ المدينة", bn = "শহর সেভ করুন" },
	["Load"] = { zh = "载入", hi = "लोड करें", es = "Cargar", fr = "Charger", ar = "تحميل", bn = "লোড করুন" },
	["City saved"] = { zh = "城市已保存", hi = "शहर सेव हो गया", es = "Ciudad guardada", fr = "Ville sauvegardée", ar = "تم حفظ المدينة", bn = "শহর সেভ হয়েছে" },
	["City autosaved"] = { zh = "城市已自动保存", hi = "शहर ऑटोसेव हुआ", es = "Ciudad autoguardada", fr = "Ville sauvegardée automatiquement", ar = "تم الحفظ التلقائي", bn = "শহর অটোসেভ হয়েছে" },
	["Save failed"] = { zh = "保存失败", hi = "सेव विफल", es = "Error al guardar", fr = "Échec de la sauvegarde", ar = "فشل الحفظ", bn = "সেভ ব্যর্থ" },
	["No cities yet"] = { zh = "还没有城市", hi = "अभी कोई शहर नहीं", es = "Aún no hay ciudades", fr = "Aucune ville pour l'instant", ar = "لا توجد مدن بعد", bn = "এখনও কোনো শহর নেই" },
	["Loading all saves\u{2026}"] = { zh = "正在载入存档…", hi = "सभी सेव लोड हो रहे हैं…", es = "Cargando partidas…", fr = "Chargement des sauvegardes…", ar = "جارٍ تحميل الحفظ…", bn = "সব সেভ লোড হচ্ছে…" },
	["Welcome back to your city"] = { zh = "欢迎回到你的城市", hi = "अपने शहर में वापस स्वागत है", es = "Bienvenido de nuevo a tu ciudad", fr = "Bon retour dans votre ville", ar = "مرحبًا بعودتك إلى مدينتك", bn = "আপনার শহরে স্বাগতম" },
	["Create a new city from the main menu."] = { zh = "从主菜单创建一座新城市。", hi = "मुख्य मेनू से नया शहर बनाएँ।", es = "Crea una ciudad nueva desde el menú principal.", fr = "Créez une nouvelle ville depuis le menu principal.", ar = "أنشئ مدينة جديدة من القائمة الرئيسية.", bn = "প্রধান মেনু থেকে নতুন শহর তৈরি করুন।" },
	["Save this city as the map default"] = { zh = "将此城市设为地图默认", hi = "इस शहर को मैप डिफ़ॉल्ट बनाएँ", es = "Guardar esta ciudad como predeterminada del mapa", fr = "Définir cette ville par défaut pour la carte", ar = "حفظ هذه المدينة كافتراضي للخريطة", bn = "এই শহরকে ম্যাপের ডিফল্ট করুন" },

	-- ------------------------------------------------------ common actions --
	["OK"] = { zh = "确定", hi = "ठीक है", es = "Aceptar", fr = "OK", ar = "موافق", bn = "ঠিক আছে" },
	["Cancel"] = { zh = "取消", hi = "रद्द करें", es = "Cancelar", fr = "Annuler", ar = "إلغاء", bn = "বাতিল" },
	["CANCEL"] = { zh = "取消", hi = "रद्द करें", es = "CANCELAR", fr = "ANNULER", ar = "إلغاء", bn = "বাতিল" },
	["Search"] = { zh = "搜索", hi = "खोजें", es = "Buscar", fr = "Rechercher", ar = "بحث", bn = "খুঁজুন" },
	["Refresh"] = { zh = "刷新", hi = "रिफ्रेश", es = "Actualizar", fr = "Actualiser", ar = "تحديث", bn = "রিফ্রেশ" },
	["Undo"] = { zh = "撤销", hi = "वापस लें", es = "Deshacer", fr = "Annuler", ar = "تراجع", bn = "আগের অবস্থা" },
	["Redo"] = { zh = "重做", hi = "फिर से करें", es = "Rehacer", fr = "Rétablir", ar = "إعادة", bn = "পুনরায় করুন" },
	["Customize"] = { zh = "自定义", hi = "कस्टमाइज़ करें", es = "Personalizar", fr = "Personnaliser", ar = "تخصيص", bn = "কাস্টমাইজ করুন" },
	["Clear All"] = { zh = "全部清除", hi = "सब हटाएँ", es = "Borrar todo", fr = "Tout effacer", ar = "مسح الكل", bn = "সব মুছুন" },
	["All"] = { zh = "全部", hi = "सभी", es = "Todo", fr = "Tout", ar = "الكل", bn = "সব" },
	["Randomize"] = { zh = "随机", hi = "रैंडम करें", es = "Aleatorio", fr = "Aléatoire", ar = "عشوائي", bn = "এলোমেলো" },
	["Ready."] = { zh = "就绪。", hi = "तैयार।", es = "Listo.", fr = "Prêt.", ar = "جاهز.", bn = "প্রস্তুত।" },
	["Checking\u{2026}"] = { zh = "检查中…", hi = "जाँच रहे हैं…", es = "Comprobando…", fr = "Vérification…", ar = "جارٍ التحقق…", bn = "পরীক্ষা হচ্ছে…" },
	["Saving\u{2026}"] = { zh = "保存中…", hi = "सेव हो रहा है…", es = "Guardando…", fr = "Sauvegarde…", ar = "جارٍ الحفظ…", bn = "সেভ হচ্ছে…" },
	["SAVING\u{2026}"] = { zh = "保存中…", hi = "सेव हो रहा है…", es = "GUARDANDO…", fr = "SAUVEGARDE…", ar = "جارٍ الحفظ…", bn = "সেভ হচ্ছে…" },
	["SOMETHING WENT WRONG"] = { zh = "出现错误", hi = "कुछ गलत हो गया", es = "ALGO SALIÓ MAL", fr = "UN PROBLÈME EST SURVENU", ar = "حدث خطأ ما", bn = "কিছু একটা ভুল হয়েছে" },
	["Restarting..."] = { zh = "正在重启...", hi = "फिर से शुरू हो रहा है...", es = "Reiniciando...", fr = "Redémarrage...", ar = "جارٍ إعادة التشغيل...", bn = "পুনরায় শুরু হচ্ছে..." },
	["Rejoin the game to start over"] = { zh = "重新加入游戏以重开", hi = "फिर से शुरू करने के लिए दोबारा जुड़ें", es = "Vuelve a entrar para empezar de nuevo", fr = "Rejoignez la partie pour recommencer", ar = "أعد الانضمام للبدء من جديد", bn = "নতুন করে শুরু করতে আবার যোগ দিন" },
	["BANKRUPT"] = { zh = "破产", hi = "दिवालिया", es = "EN BANCARROTA", fr = "EN FAILLITE", ar = "إفلاس", bn = "দেউলিয়া" },
	["Your city ran out of money and could no longer pay its bills."] = { zh = "你的城市资金耗尽，无法再支付账单。", hi = "आपके शहर का पैसा खत्म हो गया और वह बिल नहीं चुका पाया।", es = "Tu ciudad se quedó sin dinero y no pudo pagar sus facturas.", fr = "Votre ville n'a plus d'argent et ne peut plus payer ses factures.", ar = "نفدت أموال مدينتك ولم تعد قادرة على دفع فواتيرها.", bn = "আপনার শহরের অর্থ ফুরিয়ে গেছে এবং বিল পরিশোধ করতে পারছে না।" },

	-- ------------------------------------------------------- economy & HUD --
	["CITY"] = { zh = "城市", hi = "शहर", es = "CIUDAD", fr = "VILLE", ar = "المدينة", bn = "শহর" },
	["CITY HALL"] = { zh = "市政厅", hi = "सिटी हॉल", es = "AYUNTAMIENTO", fr = "HÔTEL DE VILLE", ar = "قاعة المدينة", bn = "সিটি হল" },
	["My City"] = { zh = "我的城市", hi = "मेरा शहर", es = "Mi ciudad", fr = "Ma ville", ar = "مدينتي", bn = "আমার শহর" },
	["DEMAND"] = { zh = "需求", hi = "मांग", es = "DEMANDA", fr = "DEMANDE", ar = "الطلب", bn = "চাহিদা" },
	["DISTRICTS"] = { zh = "区域", hi = "ज़िले", es = "DISTRITOS", fr = "QUARTIERS", ar = "المناطق", bn = "এলাকা" },
	["RESIDENTS"] = { zh = "居民", hi = "निवासी", es = "RESIDENTES", fr = "HABITANTS", ar = "السكان", bn = "বাসিন্দা" },
	["Residents"] = { zh = "居民", hi = "निवासी", es = "Residentes", fr = "Habitants", ar = "السكان", bn = "বাসিন্দা" },
	["WORKFORCE"] = { zh = "劳动力", hi = "कार्यबल", es = "MANO DE OBRA", fr = "MAIN-D'ŒUVRE", ar = "القوى العاملة", bn = "কর্মীশক্তি" },
	["Workers"] = { zh = "工人", hi = "कामगार", es = "Trabajadores", fr = "Travailleurs", ar = "العمال", bn = "শ্রমিক" },
	["TREASURY"] = { zh = "国库", hi = "खज़ाना", es = "TESORERÍA", fr = "TRÉSORERIE", ar = "الخزينة", bn = "কোষাগার" },
	["Budget"] = { zh = "预算", hi = "बजट", es = "Presupuesto", fr = "Budget", ar = "الميزانية", bn = "বাজেট" },
	["Economy"] = { zh = "经济", hi = "अर्थव्यवस्था", es = "Economía", fr = "Économie", ar = "الاقتصاد", bn = "অর্থনীতি" },
	["Economy & Taxes"] = { zh = "经济与税收", hi = "अर्थव्यवस्था और कर", es = "Economía e impuestos", fr = "Économie et impôts", ar = "الاقتصاد والضرائب", bn = "অর্থনীতি ও কর" },
	["TAX RATES"] = { zh = "税率", hi = "कर दरें", es = "TIPOS IMPOSITIVOS", fr = "TAUX D'IMPOSITION", ar = "معدلات الضريبة", bn = "করের হার" },
	["Taxation"] = { zh = "税收", hi = "कराधान", es = "Impuestos", fr = "Fiscalité", ar = "الضرائب", bn = "করারোপ" },
	["LOANS"] = { zh = "贷款", hi = "कर्ज़", es = "PRÉSTAMOS", fr = "PRÊTS", ar = "القروض", bn = "লোন" },
	["Loan amount"] = { zh = "贷款金额", hi = "कर्ज़ राशि", es = "Importe del préstamo", fr = "Montant du prêt", ar = "مبلغ القرض", bn = "লোনের পরিমাণ" },
	["SERVICE FUNDING"] = { zh = "服务拨款", hi = "सेवा फंडिंग", es = "FINANCIACIÓN DE SERVICIOS", fr = "FINANCEMENT DES SERVICES", ar = "تمويل الخدمات", bn = "সেবা তহবিল" },
	["INCOME / MONTH"] = { zh = "月收入", hi = "आय / माह", es = "INGRESOS / MES", fr = "REVENUS / MOIS", ar = "الدخل / شهر", bn = "আয় / মাস" },
	["EXPENSES / MONTH"] = { zh = "月支出", hi = "खर्च / माह", es = "GASTOS / MES", fr = "DÉPENSES / MOIS", ar = "المصروفات / شهر", bn = "ব্যয় / মাস" },
	["MONTHLY BALANCE"] = { zh = "月度结余", hi = "मासिक शेष", es = "BALANCE MENSUAL", fr = "SOLDE MENSUEL", ar = "الرصيد الشهري", bn = "মাসিক ব্যালান্স" },
	["BOTTOM LINE"] = { zh = "最终结果", hi = "कुल नतीजा", es = "RESULTADO FINAL", fr = "RÉSULTAT NET", ar = "المحصلة", bn = "মোট ফলাফল" },
	["ESTIMATED TOTAL"] = { zh = "预估总计", hi = "अनुमानित कुल", es = "TOTAL ESTIMADO", fr = "TOTAL ESTIMÉ", ar = "الإجمالي المقدر", bn = "আনুমানিক মোট" },
	["YIELD"] = { zh = "收益", hi = "पैदावार", es = "RENDIMIENTO", fr = "RENDEMENT", ar = "العائد", bn = "আয়" },
	["GOODS"] = { zh = "货物", hi = "सामान", es = "MERCANCÍAS", fr = "MARCHANDISES", ar = "البضائع", bn = "পণ্য" },
	["Stock"] = { zh = "库存", hi = "स्टॉक", es = "Existencias", fr = "Stock", ar = "المخزون", bn = "মজুদ" },
	["Overview"] = { zh = "概览", hi = "अवलोकन", es = "Resumen", fr = "Aperçu", ar = "نظرة عامة", bn = "সারসংক্ষেপ" },
	["TOP MILESTONE REACHED"] = { zh = "已达最高里程碑", hi = "सर्वोच्च मील का पत्थर प्राप्त", es = "HITO MÁXIMO ALCANZADO", fr = "DERNIER PALIER ATTEINT", ar = "تم بلوغ أعلى مرحلة", bn = "সর্বোচ্চ মাইলফলক অর্জিত" },
	["Top milestone reached"] = { zh = "已达最高里程碑", hi = "सर्वोच्च मील का पत्थर प्राप्त", es = "Hito máximo alcanzado", fr = "Dernier palier atteint", ar = "تم بلوغ أعلى مرحلة", bn = "সর্বোচ্চ মাইলফলক অর্জিত" },
	["Level"] = { zh = "等级", hi = "स्तर", es = "Nivel", fr = "Niveau", ar = "المستوى", bn = "স্তর" },
	["Full"] = { zh = "已满", hi = "भरा हुआ", es = "Lleno", fr = "Complet", ar = "ممتلئ", bn = "পূর্ণ" },
	["Operating"] = { zh = "运营中", hi = "चालू है", es = "En funcionamiento", fr = "En service", ar = "قيد التشغيل", bn = "চালু আছে" },
	["Provides"] = { zh = "提供", hi = "प्रदान करता है", es = "Proporciona", fr = "Fournit", ar = "يوفر", bn = "সরবরাহ করে" },
	["Coverage"] = { zh = "覆盖范围", hi = "कवरेज", es = "Cobertura", fr = "Couverture", ar = "التغطية", bn = "কভারেজ" },
	["Coverage radius"] = { zh = "覆盖半径", hi = "कवरेज त्रिज्या", es = "Radio de cobertura", fr = "Rayon de couverture", ar = "نطاق التغطية", bn = "কভারেজ ব্যাসার্ধ" },
	["Space available"] = { zh = "有空位", hi = "जगह उपलब्ध", es = "Espacio disponible", fr = "Place disponible", ar = "مساحة متاحة", bn = "জায়গা আছে" },

	-- ------------------------------------------------------ zones & services --
	["Residential"] = { zh = "住宅区", hi = "आवासीय", es = "Residencial", fr = "Résidentiel", ar = "سكني", bn = "আবাসিক" },
	["Commercial"] = { zh = "商业区", hi = "वाणिज्यिक", es = "Comercial", fr = "Commercial", ar = "تجاري", bn = "বাণিজ্যিক" },
	["Industrial"] = { zh = "工业区", hi = "औद्योगिक", es = "Industrial", fr = "Industriel", ar = "صناعي", bn = "শিল্প" },
	["Education"] = { zh = "教育", hi = "शिक्षा", es = "Educación", fr = "Éducation", ar = "التعليم", bn = "শিক্ষা" },
	["EDUCATION"] = { zh = "教育", hi = "शिक्षा", es = "EDUCACIÓN", fr = "ÉDUCATION", ar = "التعليم", bn = "শিক্ষা" },
	["Education boost"] = { zh = "教育加成", hi = "शिक्षा बढ़ावा", es = "Impulso educativo", fr = "Bonus d'éducation", ar = "تعزيز التعليم", bn = "শিক্ষা বৃদ্ধি" },
	["Pupils"] = { zh = "学生", hi = "विद्यार्थी", es = "Alumnos", fr = "Élèves", ar = "الطلاب", bn = "শিক্ষার্থী" },
	["No pupils yet"] = { zh = "还没有学生", hi = "अभी कोई विद्यार्थी नहीं", es = "Aún no hay alumnos", fr = "Aucun élève pour l'instant", ar = "لا يوجد طلاب بعد", bn = "এখনও কোনো শিক্ষার্থী নেই" },
	["Ages"] = { zh = "年龄", hi = "आयु", es = "Edades", fr = "Âges", ar = "الأعمار", bn = "বয়স" },
	["Family"] = { zh = "家庭", hi = "परिवार", es = "Familia", fr = "Famille", ar = "العائلة", bn = "পরিবার" },
	["Health"] = { zh = "健康", hi = "स्वास्थ्य", es = "Salud", fr = "Santé", ar = "الصحة", bn = "স্বাস্থ্য" },
	["Healthcare"] = { zh = "医疗", hi = "स्वास्थ्य सेवा", es = "Sanidad", fr = "Santé", ar = "الرعاية الصحية", bn = "স্বাস্থ্যসেবা" },
	["Police"] = { zh = "警察", hi = "पुलिस", es = "Policía", fr = "Police", ar = "الشرطة", bn = "পুলিশ" },
	["Fire"] = { zh = "消防", hi = "अग्निशमन", es = "Bomberos", fr = "Pompiers", ar = "الإطفاء", bn = "ফায়ার সার্ভিস" },
	["Emergency"] = { zh = "应急", hi = "आपातकाल", es = "Emergencias", fr = "Urgences", ar = "الطوارئ", bn = "জরুরি সেবা" },
	["Deathcare"] = { zh = "殖葬", hi = "अंत्येष्टि सेवा", es = "Servicios funerarios", fr = "Services funéraires", ar = "خدمات الدفن", bn = "শ্মশান সেবা" },
	["Power"] = { zh = "电力", hi = "बिजली", es = "Electricidad", fr = "Électricité", ar = "الكهرباء", bn = "বিদ্যুৎ" },
	["Sewage"] = { zh = "污水", hi = "सीवरेज", es = "Alcantarillado", fr = "Assainissement", ar = "الصرف الصحي", bn = "পয়ঃনিঃষ্কাশন" },
	["Transport"] = { zh = "交通", hi = "परिवहन", es = "Transporte", fr = "Transports", ar = "النقل", bn = "পরিবহন" },
	["TRANSPOT"] = { zh = "交通", hi = "परिवहन", es = "TRANSPORTE", fr = "TRANSPORTS", ar = "النقل", bn = "পরিবহন" },
	["Nature"] = { zh = "自然", hi = "प्रकृति", es = "Naturaleza", fr = "Nature", ar = "الطبيعة", bn = "প্রকৃতি" },
	["Terrain"] = { zh = "地形", hi = "भूभाग", es = "Terreno", fr = "Terrain", ar = "التضاريس", bn = "ভূমি" },
	["Building"] = { zh = "建筑", hi = "इमारत", es = "Edificio", fr = "Bâtiment", ar = "المبنى", bn = "ভবন" },
	["Service"] = { zh = "服务", hi = "सेवा", es = "Servicio", fr = "Service", ar = "الخدمة", bn = "সেবা" },
	["Local"] = { zh = "居民路", hi = "स्थानीय", es = "Local", fr = "Local", ar = "محلي", bn = "স্থানীয়" },
	["Urban"] = { zh = "城市路", hi = "शहरी", es = "Urbano", fr = "Urbain", ar = "حضري", bn = "শহরের" },
	["Highway"] = { zh = "高速公路", hi = "हाईवे", es = "Autopista", fr = "Autoroute", ar = "طريق سريع", bn = "হাইওয়ে" },
	["One-Way"] = { zh = "单行道", hi = "एकतरफा", es = "Sentido único", fr = "Sens unique", ar = "اتجاه واحد", bn = "একমুখী" },
	["Bus Line"] = { zh = "公交线路", hi = "बस लाइन", es = "Línea de autobús", fr = "Ligne de bus", ar = "خط الحافلة", bn = "বাস লাইন" },
	["LANES"] = { zh = "车道", hi = "लेन", es = "CARRILES", fr = "VOIES", ar = "المسارات", bn = "লেন" },
	["Road style"] = { zh = "道路样式", hi = "सड़क शैली", es = "Estilo de carretera", fr = "Style de route", ar = "نمط الطريق", bn = "রাস্তার ধরন" },
	["Upgrade road"] = { zh = "升级道路", hi = "सड़क अपग्रेड करें", es = "Mejorar carretera", fr = "Améliorer la route", ar = "ترقية الطريق", bn = "রাস্তা আপগ্রেড করুন" },
	["Upgrade"] = { zh = "升级", hi = "अपग्रेड", es = "Mejorar", fr = "Améliorer", ar = "ترقية", bn = "আপগ্রেড" },

	-- ------------------------------------------------------------- tools --
	["Bulldoze"] = { zh = "拆除", hi = "ध्वस्त करें", es = "Demoler", fr = "Démolir", ar = "هدم", bn = "ভাঙুন" },
	["Erase"] = { zh = "擦除", hi = "मिटाएँ", es = "Borrar", fr = "Effacer", ar = "مسح", bn = "মুছুন" },
	["Erase zoning"] = { zh = "清除分区", hi = "ज़ोनिंग मिटाएँ", es = "Borrar zonificación", fr = "Effacer le zonage", ar = "مسح التقسيم", bn = "জোনিং মুছুন" },
	["Paint"] = { zh = "绘制", hi = "पेंट करें", es = "Pintar", fr = "Peindre", ar = "رسم", bn = "আঁকুন" },
	["Brush"] = { zh = "笔刷", hi = "ब्रश", es = "Pincel", fr = "Pinceau", ar = "فرشاة", bn = "ব্রাশ" },
	["brush"] = { zh = "笔刷", hi = "ब्रश", es = "pincel", fr = "pinceau", ar = "فرشاة", bn = "ব্রাশ" },
	["brush size"] = { zh = "笔刷大小", hi = "ब्रश आकार", es = "tamaño del pincel", fr = "taille du pinceau", ar = "حجم الفرشاة", bn = "ব্রাশের আকার" },
	["Box"] = { zh = "矩形", hi = "बॉक्स", es = "Rectángulo", fr = "Rectangle", ar = "مستطيل", bn = "বক্স" },
	["Smooth"] = { zh = "平滑", hi = "स्मूथ", es = "Suavizar", fr = "Lisser", ar = "تنعيم", bn = "সমান করুন" },
	["Flatten"] = { zh = "削平", hi = "समतल करें", es = "Aplanar", fr = "Aplanir", ar = "تسوية", bn = "সমতল করুন" },
	["Raise"] = { zh = "抬升", hi = "ऊपर उठाएँ", es = "Elevar", fr = "Élever", ar = "رفع", bn = "উঁচু করুন" },
	["Lower"] = { zh = "降低", hi = "नीचे करें", es = "Bajar", fr = "Abaisser", ar = "خفض", bn = "নিচু করুন" },
	["Sculpt"] = { zh = "雕塑", hi = "गढ़ें", es = "Esculpir", fr = "Sculpter", ar = "نحت", bn = "গড়ুন" },
	["Mirror"] = { zh = "镜像", hi = "मिरर", es = "Reflejar", fr = "Miroir", ar = "عكس", bn = "মিরর" },
	["Parallel"] = { zh = "平行", hi = "समानांतर", es = "Paralelo", fr = "Parallèle", ar = "موازٍ", bn = "সমান্তরাল" },
	["Parallel roads"] = { zh = "平行道路", hi = "समानांतर सड़कें", es = "Carreteras paralelas", fr = "Routes parallèles", ar = "طرق متوازية", bn = "সমান্তরাল রাস্তা" },
	["Free Placement"] = { zh = "自由放置", hi = "मुक्त प्लेसमेंट", es = "Colocación libre", fr = "Placement libre", ar = "وضع حر", bn = "মুক্ত স্থাপন" },
	["Constant Slope"] = { zh = "恒定坡度", hi = "समान ढलान", es = "Pendiente constante", fr = "Pente constante", ar = "ميل ثابت", bn = "সমান ঢাল" },
	["SNAP"] = { zh = "吸附", hi = "स्नैप", es = "AJUSTE", fr = "MAGNÉTISME", ar = "محاذاة", bn = "স্ন্যাপ" },
	["Snap options"] = { zh = "吸附选项", hi = "स्नैप विकल्प", es = "Opciones de ajuste", fr = "Options de magnétisme", ar = "خيارات المحاذاة", bn = "স্ন্যাপ বিকল্প" },
	["Move It"] = { zh = "移动工具", hi = "मूव टूल", es = "Mover", fr = "Déplacer", ar = "أداة التحريك", bn = "সরানোর টুল" },
	["Toolbox"] = { zh = "工具箱", hi = "टूलबॉक्स", es = "Caja de herramientas", fr = "Boîte à outils", ar = "صندوق الأدوات", bn = "টুলবক্স" },
	["Properties"] = { zh = "属性", hi = "गुण", es = "Propiedades", fr = "Propriétés", ar = "الخصائص", bn = "বৈশিষ্ট্য" },
	["Colour"] = { zh = "颜色", hi = "रंग", es = "Color", fr = "Couleur", ar = "اللون", bn = "রঙ" },
	["Trees"] = { zh = "树木", hi = "पेड़", es = "Árboles", fr = "Arbres", ar = "الأشجار", bn = "গাছ" },
	["Bushes"] = { zh = "灌木", hi = "झाड़ियाँ", es = "Arbustos", fr = "Buissons", ar = "الشجيرات", bn = "ঝাড়" },
	["Rocks"] = { zh = "岩石", hi = "चट्टानें", es = "Rocas", fr = "Rochers", ar = "الصخور", bn = "পাথর" },
	["Trails"] = { zh = "小道", hi = "पगडंडियाँ", es = "Senderos", fr = "Sentiers", ar = "المسارات", bn = "পায়েচলা পথ" },
	["No tool selected"] = { zh = "未选择工具", hi = "कोई टूल नहीं चुना", es = "Ninguna herramienta seleccionada", fr = "Aucun outil sélectionné", ar = "لم يتم اختيار أداة", bn = "কোনো টুল নির্বাচিত নয়" },
	["Pick a building to place"] = { zh = "选择要放置的建筑", hi = "रखने के लिए इमारत चुनें", es = "Elige un edificio para colocar", fr = "Choisissez un bâtiment à placer", ar = "اختر مبنى لوضعه", bn = "স্থাপনের জন্য একটি ভবন বাছুন" },
	["Select route"] = { zh = "选择路线", hi = "रूट चुनें", es = "Seleccionar ruta", fr = "Sélectionner un trajet", ar = "تحديد المسار", bn = "রুট নির্বাচন" },
	["Show AI routes"] = { zh = "显示 AI 路线", hi = "AI रूट दिखाएँ", es = "Mostrar rutas de IA", fr = "Afficher les trajets IA", ar = "إظهار مسارات الذكاء الاصطناعي", bn = "AI রুট দেখান" },
	["Show speed labels"] = { zh = "显示限速标签", hi = "स्पीड लेबल दिखाएँ", es = "Mostrar límites de velocidad", fr = "Afficher les limites de vitesse", ar = "إظهار حدود السرعة", bn = "গতিসীমা দেখান" },
	["Disable all overlays"] = { zh = "关闭所有图层", hi = "सभी ओवरले बंद करें", es = "Desactivar todas las capas", fr = "Désactiver tous les calques", ar = "تعطيل كل الطبقات", bn = "সব ওভারলে বন্ধ করুন" },
	["Editing this lane only"] = { zh = "仅编辑此车道", hi = "केवल यह लेन संपादित हो रही है", es = "Editando solo este carril", fr = "Modification de cette voie uniquement", ar = "تعديل هذا المسار فقط", bn = "শুধু এই লেন সম্পাদনা হচ্ছে" },

	-- ------------------------------------------------------ asset editor --
	["CHOOSE AN ASSET"] = { zh = "选择资产", hi = "एक ऐसेट चुनें", es = "ELIGE UN RECURSO", fr = "CHOISISSEZ UN ÉLÉMENT", ar = "اختر عنصرًا", bn = "একটি অ্যাসেট বাছুন" },
	["WHAT KIND OF ASSET?"] = { zh = "哪种资产？", hi = "किस प्रकार का ऐसेट?", es = "¿QUÉ TIPO DE RECURSO?", fr = "QUEL TYPE D'ÉLÉMENT ?", ar = "ما نوع العنصر؟", bn = "কোন ধরনের অ্যাসেট?" },
	["Create New Asset"] = { zh = "创建新资产", hi = "नया ऐसेट बनाएँ", es = "Crear recurso nuevo", fr = "Créer un nouvel élément", ar = "إنشاء عنصر جديد", bn = "নতুন অ্যাসেট তৈরি করুন" },
	["Modify Existing Asset"] = { zh = "修改现有资产", hi = "मौजूदा ऐसेट बदलें", es = "Modificar recurso existente", fr = "Modifier un élément existant", ar = "تعديل عنصر موجود", bn = "বিদ্যমান অ্যাসেট বদলান" },
	["SAVE CREATION"] = { zh = "保存作品", hi = "रचना सेव करें", es = "GUARDAR CREACIÓN", fr = "SAUVEGARDER LA CRÉATION", ar = "حفظ الإبداع", bn = "সৃষ্টি সেভ করুন" },
	["Save..."] = { zh = "保存...", hi = "सेव करें...", es = "Guardar...", fr = "Sauvegarder...", ar = "حفظ...", bn = "সেভ করুন..." },
	["< Back"] = { zh = "< 返回", hi = "< पीछे", es = "< Atrás", fr = "< Retour", ar = "< رجوع", bn = "< পিছনে" },
	["NEXT  \u{2192}"] = { zh = "下一步 \u{2192}", hi = "आगे \u{2192}", es = "SIGUIENTE \u{2192}", fr = "SUIVANT \u{2192}", ar = "التالي \u{2192}", bn = "পরবর্তী \u{2192}" },
	["\u{2190}  BACK"] = { zh = "\u{2190} 返回", hi = "\u{2190} पीछे", es = "\u{2190} ATRÁS", fr = "\u{2190} RETOUR", ar = "\u{2190} رجوع", bn = "\u{2190} পিছনে" },

	-- ------------------------------------------------------- tool hints --
	["Click"] = { zh = "点击", hi = "क्लिक", es = "Clic", fr = "Clic", ar = "نقر", bn = "ক্লিক" },
	["Brush \u{2014} hold & scatter"] = { zh = "笔刷 \u{2014} 按住并撒布", hi = "ब्रश \u{2014} दबाकर बिखेरें", es = "Pincel \u{2014} mantén y dispersa", fr = "Pinceau \u{2014} maintenez et dispersez", ar = "فرشاة \u{2014} اضغط وانثر", bn = "ব্রাশ \u{2014} চেপে ছড়ান" },
	["Curve \u{2014} click start, bend, end"] = { zh = "曲线 \u{2014} 点击起点、弯曲、终点", hi = "वक्र \u{2014} शुरू, मोड़, अंत पर क्लिक करें", es = "Curva \u{2014} clic en inicio, curva y fin", fr = "Courbe \u{2014} cliquez début, courbe, fin", ar = "منحنى \u{2014} انقر البداية ثم الانحناء ثم النهاية", bn = "বক্ররেখা \u{2014} শুরু, বাঁক, শেষে ক্লিক করুন" },
	["Line \u{2014} click start, click end"] = { zh = "直线 \u{2014} 点击起点，点击终点", hi = "रेखा \u{2014} शुरू पर क्लिक, अंत पर क्लिक", es = "Línea \u{2014} clic en inicio, clic en fin", fr = "Ligne \u{2014} cliquez début, cliquez fin", ar = "خط \u{2014} انقر البداية ثم النهاية", bn = "রেখা \u{2014} শুরুতে ক্লিক, শেষে ক্লিক" },
	["Single \u{2014} one click, one plant"] = { zh = "单株 \u{2014} 一次点击，一棵植物", hi = "एकल \u{2014} एक क्लिक, एक पौधा", es = "Individual \u{2014} un clic, una planta", fr = "Unique \u{2014} un clic, une plante", ar = "مفرد \u{2014} نقرة واحدة، نبتة واحدة", bn = "একক \u{2014} এক ক্লিক, একটি গাছ" },
	["Pick a lane \u{2014} click a coloured disc"] = { zh = "选择车道 \u{2014} 点击彩色圆点", hi = "लेन चुनें \u{2014} रंगीन डिस्क पर क्लिक करें", es = "Elige un carril \u{2014} haz clic en un disco de color", fr = "Choisissez une voie \u{2014} cliquez sur un disque coloré", ar = "اختر مسارًا \u{2014} انقر على قرص ملون", bn = "লেন বাছুন \u{2014} রঙিন ডিস্কে ক্লিক করুন" },
	["\u{25B8} Show traffic route"] = { zh = "\u{25B8} 显示交通路线", hi = "\u{25B8} ट्रैफ़िक रूट दिखाएँ", es = "\u{25B8} Mostrar ruta de tráfico", fr = "\u{25B8} Afficher le trajet", ar = "\u{25B8} إظهار مسار المرور", bn = "\u{25B8} ট্রাফিক রুট দেখান" },
	["\u{25BE} Hide traffic route"] = { zh = "\u{25BE} 隐藏交通路线", hi = "\u{25BE} ट्रैफ़िक रूट छिपाएँ", es = "\u{25BE} Ocultar ruta de tráfico", fr = "\u{25BE} Masquer le trajet", ar = "\u{25BE} إخفاء مسار المرور", bn = "\u{25BE} ট্রাফিক রুট লুকান" },
	-- Letter-spaced in English; the translations drop the spacing, which is right --
	-- tracking CJK or Arabic like that is typographically wrong.
	["\u{26A0}  C A N ' T   B U I L D"] = { zh = "\u{26A0} 无法建造", hi = "\u{26A0} नहीं बना सकते", es = "\u{26A0} NO SE PUEDE CONSTRUIR", fr = "\u{26A0} CONSTRUCTION IMPOSSIBLE", ar = "\u{26A0} لا يمكن البناء", bn = "\u{26A0} নির্মাণ সম্ভব নয়" },
	["km/h"] = { zh = "公里/小时", hi = "किमी/घंटा", es = "km/h", fr = "km/h", ar = "كم/س", bn = "কিমি/ঘণ্টা" },
	["road width"] = { zh = "道路宽度", hi = "सड़क चौड़ाई", es = "ancho de carretera", fr = "largeur de route", ar = "عرض الطريق", bn = "রাস্তার প্রস্থ" },
	["spacing"] = { zh = "间距", hi = "अंतराल", es = "espaciado", fr = "espacement", ar = "التباعد", bn = "ব্যবধান" },
	-- Values that appear after a PREFIX below, so the whole label translates.
	["Mixed"] = { zh = "混合", hi = "मिश्रित", es = "Variados", fr = "Variées", ar = "متنوع", bn = "মিশ্র" },
	["Plastic"] = { zh = "塑料", hi = "प्लास्टिक", es = "Plástico", fr = "Plastique", ar = "بلاستيك", bn = "প্লাস্টিক" },
	["Misc"] = { zh = "其他", hi = "विविध", es = "Varios", fr = "Divers", ar = "متنوع", bn = "বিবিধ" },

	-- ---------------------------------------------------------- help copy --
	["The bars show which zones your city needs most. A longer bar means higher demand."] = { zh = "柱条显示你的城市最需要哪类区域。柱条越长，需求越高。", hi = "पट्टियाँ दिखाती हैं कि आपके शहर को किन ज़ोन की सबसे ज़्यादा ज़रूरत है। लंबी पट्टी का मतलब ज़्यादा माँग।", es = "Las barras muestran qué zonas necesita más tu ciudad. Una barra más larga significa más demanda.", fr = "Les barres indiquent les zones dont votre ville a le plus besoin. Plus la barre est longue, plus la demande est forte.", ar = "تُظهر الأشرطة المناطق التي تحتاجها مدينتك أكثر. الشريط الأطول يعني طلبًا أعلى.", bn = "বারগুলি দেখায় আপনার শহরের কোন জোন সবচেয়ে বেশি দরকার। লম্বা বার মানে বেশি চাহিদা।" },
	["Turn on Select route, then click a visible vehicle or citizen."] = { zh = "先打开「选择路线」，再点击画面中的车辆或市民。", hi = "पहले रूट चुनें चालू करें, फिर किसी दिखने वाले वाहन या नागरिक पर क्लिक करें।", es = "Activa Seleccionar ruta y luego haz clic en un vehículo o ciudadano visible.", fr = "Activez Sélectionner un trajet, puis cliquez sur un véhicule ou un citoyen visible.", ar = "فعّل تحديد المسار، ثم انقر على مركبة أو مواطن مرئي.", bn = "রুট নির্বাচন চালু করুন, তারপর দৃশ্যমান কোনো যানবাহন বা নাগরিকে ক্লিক করুন।" },
	["Unlimited money, every zone at full demand, and the whole development tree unlocked from the start. Nothing can go bankrupt. Just build."] = { zh = "资金无限，所有区域需求拉满，发展树从一开始就全部解锁。不会破产。尽情建造。", hi = "असीमित पैसा, हर ज़ोन में पूरी माँग, और शुरू से ही पूरा विकास वृक्ष अनलॉक। दिवालिया होना नामुमकिन। बस बनाते जाइए।", es = "Dinero ilimitado, todas las zonas con demanda máxima y todo el árbol de desarrollo desbloqueado desde el principio. Nada puede quebrar. Solo construye.", fr = "Argent illimité, toutes les zones à la demande maximale et tout l'arbre de développement débloqué dès le départ. Aucune faillite possible. Construisez, tout simplement.", ar = "أموال غير محدودة، وكل المناطق بأقصى طلب، وشجرة التطوير كاملة مفتوحة من البداية. لا إفلاس. ابنِ فحسب.", bn = "সীমাহীন অর্থ, প্রতিটি জোনে পূর্ণ চাহিদা, এবং শুরু থেকেই সম্পূর্ণ ডেভেলপমেন্ট ট্রি আনলক। দেউলিয়া হওয়ার সুযোগ নেই। শুধু গড়ে তুলুন।" },
}

-- Labels the game rebuilds as `prefix .. live value` -- "Snap: On", "Lv 3",
-- "Pop 1,240". Only the leading text is translated; whatever follows is the
-- value and passes through untouched.
local PREFIXES: { [string]: { [string]: string } } = {
	["Snap: "] = { zh = "吸附：", hi = "स्नैप: ", es = "Ajuste: ", fr = "Magnétisme : ", ar = "المحاذاة: ", bn = "স্ন্যাপ: " },
	["Size: "] = { zh = "尺寸：", hi = "आकार: ", es = "Tamaño: ", fr = "Taille : ", ar = "الحجم: ", bn = "আকার: " },
	["Sizes: "] = { zh = "尺寸：", hi = "आकार: ", es = "Tamaños: ", fr = "Tailles : ", ar = "الأحجام: ", bn = "আকার: " },
	["Material: "] = { zh = "材质：", hi = "सामग्री: ", es = "Material: ", fr = "Matériau : ", ar = "المادة: ", bn = "উপাদান: " },
	["Category: "] = { zh = "类别：", hi = "श्रेणी: ", es = "Categoría: ", fr = "Catégorie : ", ar = "الفئة: ", bn = "বিভাগ: " },
	["Move: "] = { zh = "移动：", hi = "मूव: ", es = "Mover: ", fr = "Déplacer : ", ar = "تحريك: ", bn = "সরান: " },
	["Rotate: "] = { zh = "旋转：", hi = "घुमाएँ: ", es = "Rotar: ", fr = "Rotation : ", ar = "تدوير: ", bn = "ঘোরান: " },
	["Offset: "] = { zh = "偏移：", hi = "ऑफ़सेट: ", es = "Desplazamiento: ", fr = "Décalage : ", ar = "الإزاحة: ", bn = "অফসেট: " },
	["Gap: "] = { zh = "间隙：", hi = "गैप: ", es = "Separación: ", fr = "Écart : ", ar = "الفجوة: ", bn = "ফাঁক: " },
	["Can't place: "] = { zh = "无法放置：", hi = "रख नहीं सकते: ", es = "No se puede colocar: ", fr = "Placement impossible : ", ar = "لا يمكن الوضع: ", bn = "রাখা যাচ্ছে না: " },
	["Lv "] = { zh = "等级 ", hi = "स्तर ", es = "Nv ", fr = "Niv ", ar = "مستوى ", bn = "স্তর " },
	["Pop "] = { zh = "人口 ", hi = "जनसंख्या ", es = "Pob ", fr = "Pop ", ar = "السكان ", bn = "জনসংখ্যা " },
	["Rate "] = { zh = "税率 ", hi = "दर ", es = "Tasa ", fr = "Taux ", ar = "المعدل ", bn = "হার " },
	["Jobs "] = { zh = "岗位 ", hi = "नौकरियाँ ", es = "Empleos ", fr = "Emplois ", ar = "الوظائف ", bn = "চাকরি " },
	["No. "] = { zh = "编号 ", hi = "क्र. ", es = "N.º ", fr = "N° ", ar = "رقم ", bn = "নং " },
	["ALL CLEAR  \u{00B7}  "] = { zh = "一切正常  \u{00B7}  ", hi = "सब ठीक  \u{00B7}  ", es = "TODO EN ORDEN  \u{00B7}  ", fr = "TOUT VA BIEN  \u{00B7}  ", ar = "كل شيء على ما يرام  \u{00B7}  ", bn = "সব ঠিক আছে  \u{00B7}  " },
	["Education  \u{00B7}  "] = { zh = "教育  \u{00B7}  ", hi = "शिक्षा  \u{00B7}  ", es = "Educación  \u{00B7}  ", fr = "Éducation  \u{00B7}  ", ar = "التعليم  \u{00B7}  ", bn = "শিক্ষা  \u{00B7}  " },
	["Emergency Service  \u{00B7}  "] = { zh = "应急服务  \u{00B7}  ", hi = "आपातकालीन सेवा  \u{00B7}  ", es = "Servicio de emergencia  \u{00B7}  ", fr = "Service d'urgence  \u{00B7}  ", ar = "خدمة الطوارئ  \u{00B7}  ", bn = "জরুরি সেবা  \u{00B7}  " },
}

-- German, added after the fact. Kept as a flat pack merged into the tables
-- above rather than a `de =` field threaded through 319 existing rows -- the
-- merge runs once at load and consumers can't tell the difference. Any further
-- language goes in the same shape.
local GERMAN: { [string]: string } = {
	["Control Room"] = "Leitstelle", ["Graphics"] = "Grafik", ["Gameplay"] = "Spiel",
	["Audio"] = "Audio", ["Interface"] = "Oberfläche", ["Input"] = "Steuerung",
	["General"] = "Allgemein", ["Language"] = "Sprache",
	["Quality preset"] = "Qualitätsvorgabe", ["Detail"] = "Detail",
	["Shadow quality"] = "Schattenqualität", ["Draw distance"] = "Sichtweite",
	["Effects"] = "Effekte", ["Bloom"] = "Bloom", ["Sun rays"] = "Sonnenstrahlen",
	["Depth of field"] = "Tiefenschärfe", ["Atmosphere haze"] = "Dunst",
	["Water"] = "Wasser", ["Water waves"] = "Wasserwellen",
	["Water reflections"] = "Wasserspiegelungen", ["Water clarity"] = "Wasserklarheit",
	["Effect strength"] = "Effektstärke", ["Bloom intensity"] = "Bloom-Intensität",
	["Sun ray intensity"] = "Strahlenintensität", ["Haze density"] = "Dunstdichte",
	["Color grading"] = "Farbkorrektur", ["Color grade"] = "Farbabstimmung",
	["Saturation"] = "Sättigung", ["Contrast"] = "Kontrast", ["Brightness"] = "Helligkeit",
	["Exposure"] = "Belichtung", ["Correct each colour"] = "Jede Farbe korrigieren",
	["Red"] = "Rot", ["Green"] = "Grün", ["Blue"] = "Blau",
	["Autosave"] = "Autospeichern", ["Autosave interval"] = "Autospeicher-Intervall",
	["Day/night cycle"] = "Tag/Nacht-Zyklus", ["Start paused"] = "Pausiert starten",
	["Show FPS"] = "FPS anzeigen", ["Every minute"] = "Jede Minute",
	["Every 2 minutes"] = "Alle 2 Minuten", ["Every 5 minutes"] = "Alle 5 Minuten",
	["Every 10 minutes"] = "Alle 10 Minuten", ["Every 15 minutes"] = "Alle 15 Minuten",
	["Every 30 minutes"] = "Alle 30 Minuten", ["Every hour"] = "Jede Stunde",
	["Master volume"] = "Gesamtlautstärke", ["Music volume"] = "Musiklautstärke",
	["Sound effects"] = "Soundeffekte", ["Ambience"] = "Umgebung",
	["Layout"] = "Layout", ["HUD scale"] = "HUD-Größe", ["UI transparency"] = "UI-Transparenz",
	["Frosted glass"] = "Milchglas", ["Prompts"] = "Hinweise", ["Tooltips"] = "Tooltips",
	["Notifications"] = "Benachrichtigungen", ["Units"] = "Einheiten",
	["Clock format"] = "Zeitformat", ["Distance"] = "Entfernung",
	["12 hour"] = "12 Stunden", ["24 hour"] = "24 Stunden",
	["Metric (km)"] = "Metrisch (km)", ["Imperial (mi)"] = "Imperial (mi)", ["Studs"] = "Studs",
	["Camera"] = "Kamera", ["Camera forward"] = "Kamera vorwärts",
	["Camera back"] = "Kamera rückwärts", ["Camera left"] = "Kamera links",
	["Camera right"] = "Kamera rechts", ["Rotate left"] = "Nach links drehen",
	["Rotate right"] = "Nach rechts drehen", ["Camera up"] = "Kamera hoch",
	["Camera down"] = "Kamera runter", ["Camera feel"] = "Kameraverhalten",
	["Camera speed"] = "Kamerageschwindigkeit", ["Rotation speed"] = "Drehgeschwindigkeit",
	["Zoom speed"] = "Zoomgeschwindigkeit", ["Mouse sensitivity"] = "Mausempfindlichkeit",
	["Edge scrolling"] = "Randscrollen", ["Reset to defaults"] = "Auf Standard zurücksetzen",
	["PRESS KEY"] = "TASTE DRÜCKEN",
	["On"] = "An", ["Off"] = "Aus", ["Hard"] = "Hart", ["Soft"] = "Weich",
	["Simple"] = "Einfach", ["Advanced"] = "Erweitert", ["Low"] = "Niedrig",
	["Medium"] = "Mittel", ["High"] = "Hoch", ["Ultra"] = "Ultra",
	["Custom"] = "Benutzerdefiniert", ["Before"] = "Vorher", ["After"] = "Nachher",

	["PLAY"] = "SPIELEN", ["CONTINUE"] = "FORTSETZEN", ["NEW GAME"] = "NEUES SPIEL",
	["LOAD GAME"] = "SPIEL LADEN", ["LOADING GAME"] = "SPIEL WIRD GELADEN",
	["SETTINGS"] = "EINSTELLUNGEN", ["Settings"] = "Einstellungen",
	["Game Settings"] = "Spieleinstellungen", ["CREDITS"] = "MITWIRKENDE",
	["Exit"] = "Beenden", ["MENU"] = "MENÜ", ["Main Menu"] = "Hauptmenü",
	["Return to Main Menu"] = "Zurück zum Hauptmenü", ["Return to Menu"] = "Zurück zum Menü",
	["Resume"] = "Fortsetzen", ["CONTENT HUB"] = "INHALTE", ["Content Hub"] = "Inhalte",
	["MY CREATIONS"] = "MEINE KREATIONEN", ["My Creations"] = "Meine Kreationen",
	["CREATION EDITOR"] = "KREATIONS-EDITOR", ["EDITOR"] = "EDITOR",
	["Open Editor"] = "Editor öffnen", ["UPDATE LOG"] = "ÄNDERUNGSPROTOKOLL",
	["UPDATE LOGS"] = "ÄNDERUNGSPROTOKOLLE", ["DASHBOARDS"] = "ÜBERSICHTEN",
	["City Dashboard"] = "Stadtübersicht", ["Info & dashboards"] = "Infos & Übersichten",
	["Info Panel"] = "Infofenster", ["SANDBOX"] = "SANDKASTEN",
	["SANDBOX MODE"] = "SANDKASTEN-MODUS",

	["FOUND CITY"] = "STADT GRÜNDEN", ["SELECT YOUR MAP"] = "KARTE WÄHLEN",
	["SEED"] = "SEED", ["REROLL SEED"] = "NEUER SEED", ["STEP 1 / 2"] = "SCHRITT 1 / 2",
	["SAVE CITY"] = "STADT SPEICHERN", ["LOAD CITY"] = "STADT LADEN",
	["DELETE CITY"] = "STADT LÖSCHEN", ["RENAME CITY"] = "STADT UMBENENNEN",
	["RENAME"] = "UMBENENNEN", ["DELETE"] = "LÖSCHEN", ["Delete"] = "Löschen",
	["Save"] = "Speichern", ["Save City"] = "Stadt speichern", ["Load"] = "Laden",
	["City saved"] = "Stadt gespeichert", ["City autosaved"] = "Stadt automatisch gespeichert",
	["Save failed"] = "Speichern fehlgeschlagen", ["No cities yet"] = "Noch keine Städte",
	["Loading all saves\u{2026}"] = "Alle Spielstände werden geladen\u{2026}",
	["Welcome back to your city"] = "Willkommen zurück in deiner Stadt",
	["Create a new city from the main menu."] = "Erstelle im Hauptmenü eine neue Stadt.",
	["Save this city as the map default"] = "Diese Stadt als Kartenstandard speichern",

	["OK"] = "OK", ["Cancel"] = "Abbrechen", ["CANCEL"] = "ABBRECHEN",
	["Search"] = "Suchen", ["Refresh"] = "Aktualisieren", ["Undo"] = "Rückgängig",
	["Redo"] = "Wiederholen", ["Customize"] = "Anpassen", ["Clear All"] = "Alles löschen",
	["All"] = "Alle", ["Randomize"] = "Zufällig", ["Ready."] = "Bereit.",
	["Checking\u{2026}"] = "Wird geprüft\u{2026}", ["Saving\u{2026}"] = "Wird gespeichert\u{2026}",
	["SAVING\u{2026}"] = "WIRD GESPEICHERT\u{2026}",
	["SOMETHING WENT WRONG"] = "ETWAS IST SCHIEFGELAUFEN",
	["Restarting..."] = "Wird neu gestartet...",
	["Rejoin the game to start over"] = "Betritt das Spiel erneut, um neu zu starten",
	["BANKRUPT"] = "BANKROTT",
	["Your city ran out of money and could no longer pay its bills."] = "Deiner Stadt ist das Geld ausgegangen und sie konnte ihre Rechnungen nicht mehr bezahlen.",

	["CITY"] = "STADT", ["CITY HALL"] = "RATHAUS", ["My City"] = "Meine Stadt",
	["DEMAND"] = "NACHFRAGE", ["DISTRICTS"] = "BEZIRKE", ["RESIDENTS"] = "EINWOHNER",
	["Residents"] = "Einwohner", ["WORKFORCE"] = "ARBEITSKRÄFTE", ["Workers"] = "Arbeiter",
	["TREASURY"] = "STADTKASSE", ["Budget"] = "Budget", ["Economy"] = "Wirtschaft",
	["Economy & Taxes"] = "Wirtschaft & Steuern", ["TAX RATES"] = "STEUERSÄTZE",
	["Taxation"] = "Besteuerung", ["LOANS"] = "KREDITE", ["Loan amount"] = "Kreditbetrag",
	["SERVICE FUNDING"] = "DIENSTFINANZIERUNG", ["INCOME / MONTH"] = "EINNAHMEN / MONAT",
	["EXPENSES / MONTH"] = "AUSGABEN / MONAT", ["MONTHLY BALANCE"] = "MONATSBILANZ",
	["BOTTOM LINE"] = "ERGEBNIS", ["ESTIMATED TOTAL"] = "GESCHÄTZTE SUMME",
	["YIELD"] = "ERTRAG", ["GOODS"] = "WAREN", ["Stock"] = "Bestand",
	["Overview"] = "Übersicht",
	["TOP MILESTONE REACHED"] = "HÖCHSTER MEILENSTEIN ERREICHT",
	["Top milestone reached"] = "Höchster Meilenstein erreicht",
	["Level"] = "Stufe", ["Full"] = "Voll", ["Operating"] = "In Betrieb",
	["Provides"] = "Bietet", ["Coverage"] = "Abdeckung",
	["Coverage radius"] = "Abdeckungsradius", ["Space available"] = "Platz verfügbar",

	["Residential"] = "Wohngebiet", ["Commercial"] = "Gewerbe", ["Industrial"] = "Industrie",
	["Education"] = "Bildung", ["EDUCATION"] = "BILDUNG", ["Education boost"] = "Bildungsbonus",
	["Pupils"] = "Schüler", ["No pupils yet"] = "Noch keine Schüler", ["Ages"] = "Alter",
	["Family"] = "Familie", ["Health"] = "Gesundheit", ["Healthcare"] = "Gesundheitswesen",
	["Police"] = "Polizei", ["Fire"] = "Feuerwehr", ["Emergency"] = "Notdienste",
	["Deathcare"] = "Bestattung", ["Power"] = "Strom", ["Sewage"] = "Abwasser",
	["Transport"] = "Verkehr", ["TRANSPOT"] = "VERKEHR", ["Nature"] = "Natur",
	["Terrain"] = "Gelände", ["Building"] = "Gebäude", ["Service"] = "Dienst",
	["Local"] = "Anliegerstraße", ["Urban"] = "Stadtstraße", ["Highway"] = "Autobahn",
	["One-Way"] = "Einbahnstraße", ["Bus Line"] = "Buslinie", ["LANES"] = "SPUREN",
	["Road style"] = "Straßenstil", ["Upgrade road"] = "Straße ausbauen", ["Upgrade"] = "Ausbauen",

	["Bulldoze"] = "Abreißen", ["Erase"] = "Löschen", ["Erase zoning"] = "Zonen löschen",
	["Paint"] = "Malen", ["Brush"] = "Pinsel", ["brush"] = "Pinsel",
	["brush size"] = "Pinselgröße", ["Box"] = "Rechteck", ["Smooth"] = "Glätten",
	["Flatten"] = "Ebnen", ["Raise"] = "Anheben", ["Lower"] = "Absenken",
	["Sculpt"] = "Formen", ["Mirror"] = "Spiegeln", ["Parallel"] = "Parallel",
	["Parallel roads"] = "Parallele Straßen", ["Free Placement"] = "Freie Platzierung",
	["Constant Slope"] = "Konstante Steigung", ["SNAP"] = "RASTER",
	["Snap options"] = "Rasteroptionen", ["Move It"] = "Verschieben",
	["Toolbox"] = "Werkzeugkasten", ["Properties"] = "Eigenschaften", ["Colour"] = "Farbe",
	["Trees"] = "Bäume", ["Bushes"] = "Sträucher", ["Rocks"] = "Felsen", ["Trails"] = "Wege",
	["No tool selected"] = "Kein Werkzeug gewählt",
	["Pick a building to place"] = "Wähle ein Gebäude zum Platzieren",
	["Select route"] = "Route wählen", ["Show AI routes"] = "KI-Routen anzeigen",
	["Show speed labels"] = "Tempolimits anzeigen",
	["Disable all overlays"] = "Alle Overlays ausschalten",
	["Editing this lane only"] = "Nur diese Spur wird bearbeitet",

	["CHOOSE AN ASSET"] = "ASSET WÄHLEN", ["WHAT KIND OF ASSET?"] = "WELCHE ART VON ASSET?",
	["Create New Asset"] = "Neues Asset erstellen",
	["Modify Existing Asset"] = "Vorhandenes Asset ändern",
	["SAVE CREATION"] = "KREATION SPEICHERN", ["Save..."] = "Speichern...",
	["< Back"] = "< Zurück", ["NEXT  \u{2192}"] = "WEITER \u{2192}", ["\u{2190}  BACK"] = "\u{2190} ZURÜCK",

	["Click"] = "Klick",
	["Brush \u{2014} hold & scatter"] = "Pinsel \u{2014} halten & streuen",
	["Curve \u{2014} click start, bend, end"] = "Kurve \u{2014} Start, Bogen, Ende anklicken",
	["Line \u{2014} click start, click end"] = "Linie \u{2014} Start anklicken, Ende anklicken",
	["Single \u{2014} one click, one plant"] = "Einzeln \u{2014} ein Klick, eine Pflanze",
	["Pick a lane \u{2014} click a coloured disc"] = "Spur wählen \u{2014} auf eine farbige Scheibe klicken",
	["\u{25B8} Show traffic route"] = "\u{25B8} Route anzeigen",
	["\u{25BE} Hide traffic route"] = "\u{25BE} Route ausblenden",
	["\u{26A0}  C A N ' T   B U I L D"] = "\u{26A0} BAU NICHT MÖGLICH",
	["km/h"] = "km/h", ["road width"] = "Straßenbreite", ["spacing"] = "Abstand",
	["Mixed"] = "Gemischt", ["Plastic"] = "Kunststoff", ["Misc"] = "Sonstiges",

	["The bars show which zones your city needs most. A longer bar means higher demand."] = "Die Balken zeigen, welche Zonen deine Stadt am dringendsten braucht. Ein längerer Balken bedeutet höhere Nachfrage.",
	["Turn on Select route, then click a visible vehicle or citizen."] = "Schalte Route wählen ein und klicke dann auf ein sichtbares Fahrzeug oder einen Bürger.",
	["Unlimited money, every zone at full demand, and the whole development tree unlocked from the start. Nothing can go bankrupt. Just build."] = "Unbegrenztes Geld, jede Zone mit voller Nachfrage und der komplette Entwicklungsbaum von Anfang an freigeschaltet. Nichts kann bankrottgehen. Bau einfach.",
}

local GERMAN_PREFIXES: { [string]: string } = {
	["Snap: "] = "Raster: ", ["Size: "] = "Größe: ", ["Sizes: "] = "Größen: ",
	["Material: "] = "Material: ", ["Category: "] = "Kategorie: ",
	["Move: "] = "Verschieben: ", ["Rotate: "] = "Drehen: ", ["Offset: "] = "Versatz: ",
	["Gap: "] = "Abstand: ", ["Can't place: "] = "Platzierung nicht möglich: ",
	["Lv "] = "Stufe ", ["Pop "] = "Einw. ", ["Rate "] = "Satz ", ["Jobs "] = "Jobs ",
	["No. "] = "Nr. ",
	["ALL CLEAR  \u{00B7}  "] = "ALLES IN ORDNUNG  \u{00B7}  ",
	["Education  \u{00B7}  "] = "Bildung  \u{00B7}  ",
	["Emergency Service  \u{00B7}  "] = "Notdienst  \u{00B7}  ",
}

-- Merge, and shout about a key that no longer exists rather than silently
-- dropping the translation on the floor.
for key, text in GERMAN do
	local forms = STRINGS[key]
	if forms then
		forms.de = text
	else
		warn("[Locale] German entry for a string that is gone: " .. key)
	end
end
for key, text in GERMAN_PREFIXES do
	local forms = PREFIXES[key]
	if forms then
		forms.de = text
	else
		warn("[Locale] German prefix for a prefix that is gone: " .. key)
	end
end

local SRC_ATTR = "LocaleSrc"
local DEFAULT = "en"

-- Lookup key: spacing and case dropped, so the letter-spaced headers
-- ("G R A P H I C S ") and upper-cased chips ("ULTRA") hit the same entry as
-- the plain string.
local function norm(text: string): string
	return (string.lower((string.gsub(text, "%s+", ""))))
end

local INDEX: { [string]: string } = {}
for key, forms in STRINGS do
	INDEX[norm(key)] = key
	for _, text in forms do
		INDEX[norm(text)] = key
	end
end
table.freeze(INDEX)

local _lang = DEFAULT
local _started = false
local _conn: RBXScriptConnection? = nil

local function translated(key: string): string
	if _lang == DEFAULT then return key end
	local forms = STRINGS[key]
	return (if forms then forms[_lang] else nil) or key
end

-- Every prefix form in every language, longest first so "Sizes: " is tested
-- before "Size: ".
local PREFIX_FORMS: { { text: string, key: string } } = {}
for key, forms in PREFIXES do
	table.insert(PREFIX_FORMS, { text = key, key = key })
	for _, text in forms do
		table.insert(PREFIX_FORMS, { text = text, key = key })
	end
end
table.sort(PREFIX_FORMS, function(a, b)
	return #a.text > #b.text
end)

local function translatedPrefix(key: string): string
	if _lang == DEFAULT then return key end
	local forms = PREFIXES[key]
	return (if forms then forms[_lang] else nil) or key
end

-- Our own writes must not look like the game updating a value.
local _busy = false
local _watched: { [Instance]: RBXScriptConnection } = {}

local function write(label: TextLabel, text: string)
	if label.Text == text then return end
	_busy = true
	label.Text = text
	_busy = false
end

-- A value label gets rewritten by its owner in English every time the value
-- changes, so a one-off sweep isn't enough -- follow it.
local function watch(label: TextLabel)
	if _watched[label] then return end
	local conn = label:GetPropertyChangedSignal("Text"):Connect(function()
		if not _busy then
			Locale.applyTo(label)
		end
	end)
	_watched[label] = conn
	label.Destroying:Once(function()
		conn:Disconnect()
		_watched[label] = nil
	end)
end

-- Prefix path: read the CURRENT text, never a stored original. A stored one
-- goes stale the instant the owner writes a new value, and re-applying it would
-- put the old value back.
local function applyPrefix(label: TextLabel): boolean
	local text = label.Text
	for _, form in PREFIX_FORMS do
		if string.sub(text, 1, #form.text) ~= form.text then continue end
		local tail = string.sub(text, #form.text + 1)
		local tailKey = INDEX[norm(tail)]
		write(label, translatedPrefix(form.key) .. (if tailKey then translated(tailKey) else tail))
		watch(label)
		return true
	end
	return false
end

-- One label. Anything that matches neither the index nor a prefix is fully
-- dynamic text and is left untouched.
function Locale.applyTo(obj: Instance)
	if not obj:IsA("TextLabel") and not obj:IsA("TextButton") then return end
	local label = obj :: TextLabel
	local src = label:GetAttribute(SRC_ATTR)
	if typeof(src) ~= "string" then
		if not INDEX[norm(label.Text)] then
			applyPrefix(label)
			return
		end
		src = label.Text
		label:SetAttribute(SRC_ATTR, src)
	end
	local key = INDEX[norm(src :: string)]
	if not key then return end
	-- English restores the ORIGINAL text, keeping whatever styling the builder
	-- applied (letter spacing, upper case) that the key alone can't express.
	write(label, if _lang == DEFAULT then src :: string else translated(key))
end

-- Sweeps a subtree. Takes a root so it can be run over anything -- the live
-- PlayerGui in game, a plain folder of labels in a test.
function Locale.apply(root: Instance)
	for _, d in root:GetDescendants() do
		Locale.applyTo(d)
	end
end

local function applyAll()
	local player = Players.LocalPlayer
	local gui = if player then player:FindFirstChild("PlayerGui") else nil
	if not gui then return end
	Locale.apply(gui)
end

function Locale.options(): { Option }
	return table.clone(LANGUAGES)
end

function Locale.get(): string
	return _lang
end

-- Is this string translatable at all? A translation that happens to equal the
-- English (Spanish "Simple", French "Ultra") is still coverage, so comparing
-- rendered text can't answer this -- coverage checks ask here instead.
function Locale.has(text: string): boolean
	if INDEX[norm(text)] then return true end
	for _, form in PREFIX_FORMS do
		if string.sub(text, 1, #form.text) == form.text then return true end
	end
	return false
end

function Locale.setLanguage(code: string)
	local known = false
	for _, option in LANGUAGES do
		if option.value == code then
			known = true
			break
		end
	end
	if not known or code == _lang then return end
	_lang = code
	applyAll()
end

-- Late-built UI (panels open long after boot) is caught by DescendantAdded.
-- Deferred because builders usually parent the label first and set Text after.
function Locale.Start()
	if _started then return end
	_started = true
	local gui = Players.LocalPlayer:WaitForChild("PlayerGui")
	_conn = gui.DescendantAdded:Connect(function(d)
		task.defer(Locale.applyTo, d)
	end)
	applyAll()
end

return Locale
