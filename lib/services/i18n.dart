// lib/services/i18n.dart
// Lightweight i18n for SAIL Safety Lens — supports EN, HI
// Usage:
//   String x = I18n.t('home.welcome');
//   I18n.setLocale('hi');
//   listen to I18n.instance to rebuild on language change

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class I18n extends ChangeNotifier {
  static final I18n instance = I18n._();
  I18n._();

  static const _kLocaleKey = 'app_locale_lang';
  static const List<String> supportedCodes = ['en', 'hi'];

  Locale _locale = const Locale('en');
  Locale get locale => _locale;

  static String get currentLang => instance._locale.languageCode;

  /// Read saved preference + initialise locale. Call once in main().
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_kLocaleKey);
    if (saved != null && supportedCodes.contains(saved)) {
      instance._locale = Locale(saved);
    }
  }

  /// Switch language and persist
  static Future<void> setLocale(String code) async {
    if (!supportedCodes.contains(code)) return;
    if (instance._locale.languageCode == code) return;
    instance._locale = Locale(code);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLocaleKey, code);
    instance.notifyListeners();
  }

  /// Cycle through languages: en→hi→en
  static Future<void> toggle() async {
    final idx = supportedCodes.indexOf(currentLang);
    final next = supportedCodes[(idx + 1) % supportedCodes.length];
    await setLocale(next);
  }

  /// Get language display name (English names for universal understanding)
  static String langName(String code) {
    switch (code) {
      case 'hi': return 'Hindi';
      default:   return 'English';
    }
  }

  /// Lookup translation by dot-notation key; falls back to EN then key itself.
  static String t(String key, {Map<String, String>? args}) {
    final Map<String, String> table;
    switch (currentLang) {
      case 'hi': table = _hi; break;
      default:   table = _en; break;
    }
    var value = table[key] ?? _en[key] ?? key;
    if (args != null) {
      args.forEach((k, v) => value = value.replaceAll('{$k}', v));
    }
    return value;
  }

  // ──────────────────────────────────────────────────────────────
  //  ENGLISH STRINGS
  // ──────────────────────────────────────────────────────────────
  static const Map<String, String> _en = {
    'app.name'             : 'SAIL Safety Lens',
    'app.tagline'          : 'AI Safety Platform',

    'common.save'          : 'Save',
    'common.cancel'        : 'Cancel',
    'common.close'         : 'Close',
    'common.delete'        : 'Delete',
    'common.edit'          : 'Edit',
    'common.add'           : 'Add',
    'common.submit'        : 'Submit',
    'common.export'        : 'Export',
    'common.search'        : 'Search',
    'common.filter'        : 'Filter',
    'common.refresh'       : 'Refresh',
    'common.sync'          : 'Sync',
    'common.loading'       : 'Loading…',
    'common.success'       : 'Success',
    'common.failed'        : 'Failed',
    'common.yes'           : 'Yes',
    'common.no'            : 'No',
    'common.ok'            : 'OK',
    'common.back'          : 'Back',
    'common.next'          : 'Next',
    'common.continue'      : 'Continue',
    'common.retry'         : 'Retry',

    'tab.home'             : 'Home',
    'tab.aiScan'           : 'AI Scan',
    'tab.nearMiss'         : 'Near Miss',
    'tab.askAi'            : 'Ask AI',
    'tab.reports'          : 'Reports',

    'home.welcome'         : 'Welcome',
    'home.dashboard'       : 'Safety Dashboard',
    'home.totalCases'      : 'Total Cases',
    'home.openCases'       : 'Open',
    'home.closedCases'     : 'Closed',
    'home.criticalCases'   : 'Critical',
    'home.thisMonth'       : 'This Month',
    'home.thisWeek'        : 'This Week',
    'home.today'           : 'Today',
    'home.quickActions'    : 'Quick Actions',
    'home.recentActivity'  : 'Recent Activity',
    'home.safetyStats'     : 'Safety Statistics',
    'home.byPlant'         : 'By Plant',
    'home.bySeverity'      : 'By Severity',
    'home.daysSinceLti'    : 'Days since LTI',
    'home.safetyScore'     : 'Safety Score',
    'home.viewAll'         : 'View All',
    'home.noData'          : 'No incidents yet',
    'home.startScan'       : 'Start AI Scan',
    'home.reportNearMiss'  : 'Report Near Miss',
    'home.viewReports'     : 'View Reports',
    'home.askExpert'       : 'Ask Expert',
    'home.scanSop'         : 'Scan SOP / SMP',
    // Kept to two words. This label sits in a half-width quick-action card
    // beside "Scan SOP / SMP", and anything longer wraps to three lines and
    // pushes the card taller than the one next to it.
    'home.askDocument'     : 'Ask a Document',
    'home.greeting.morning': 'Good morning',
    'home.greeting.afternoon': 'Good afternoon',
    'home.greeting.evening': 'Good evening',
    'home.weeklyTrend'     : 'Weekly Trend',
    'home.topHazards'      : 'Top Hazards',

    'aiScan.title'         : 'MAMR',
    // Was 'Gemini Vision · IS 14489 · WSA 13 · Factories Act'. Four
    // dot-separated tokens in an 11px line under the title is the densest text
    // in the app and it told the reader nothing they could act on: the statutes
    // are cited per hazard in the report itself, where they can be checked, and
    // "Gemini Vision" names a vendor that the tier chain may not even have used
    // for this photograph. The subtitle now says what the screen does.
    'aiScan.subtitle'      : 'My Area My Responsibility',
    'aiScan.capture'       : 'Capture',
    'aiScan.aiScan'        : 'AI Scan',
    'aiScan.review'        : 'Review',
    'aiScan.save'          : 'Save',
    'aiScan.mitigate'      : 'Mitigate',
    'aiScan.takePhoto'     : 'Capture workplace photo',
    'aiScan.aiDetects'     : 'AI detects hazards & marks them on photo',
    'aiScan.camera'        : 'Camera',
    'aiScan.gallery'       : 'Gallery',
    'aiScan.analyzing'     : 'Analyzing photo…',
    'aiScan.summary'       : 'Summary',
    'aiScan.hazardAnalysis': 'Hazard Analysis',
    'aiScan.overallRisk'   : 'Overall Risk',
    'aiScan.confidence'    : 'confidence',
    'aiScan.savedToSheets' : 'Saved to Google Sheets',
    'aiScan.newScan'       : 'New',
    'aiScan.pdf'           : 'PDF',
    'aiScan.howItWorks'    : 'How AI Hazard Scan works',

    'nearMiss.title'       : 'Near Miss / Unsafe Condition',
    'nearMiss.brief'       : 'Brief description',
    'nearMiss.briefHint'   : 'What happened? (Voice or text)',
    'nearMiss.plant'       : 'Plant',
    'nearMiss.dept'        : 'Department',
    'nearMiss.location'    : 'Location',
    'nearMiss.severity'    : 'Severity',
    'nearMiss.people'      : 'No. of people involved',
    'nearMiss.description' : 'Detailed description',
    'nearMiss.action'      : 'Immediate action taken',
    'nearMiss.uploadImage' : 'Upload Image',
    'nearMiss.submit'      : 'Submit Report',
    'nearMiss.submitExport': 'Submit + Export PDF',
    'nearMiss.recording'   : 'Listening…',
    'nearMiss.tapToTalk'   : 'Tap mic to dictate',

    'reports.title'        : 'Reports',
    'reports.heading'      : 'Analytics & Reports',
    'reports.tab.overview' : 'Overview',
    'reports.tab.log'      : 'Log',
    'reports.tab.analysis' : 'Analysis',
    'reports.tab.plantWise': 'Plant Wise',
    'reports.all'          : 'All',
    'reports.open'         : 'Open',
    'reports.closed'       : 'Closed',
    'reports.critical'     : 'Critical',
    'reports.high'         : 'High',
    'reports.medium'       : 'Medium',
    'reports.low'          : 'Low',
    'reports.plant'        : 'Plant / Unit',
    'reports.byPlant'      : 'Filter by Plant',
    'reports.allPlants'    : 'All Plants',
    'reports.export'       : 'Export PDF',
    'reports.exportSheets' : 'Open in Sheets',
    'reports.noReports'    : 'No reports found',
    'reports.sortBy'       : 'Sort by',
    'reports.date'         : 'Date',
    'reports.severity'     : 'Severity',
    'reports.score'        : 'Risk Score',
    'reports.status'       : 'Status',

    'settings.title'       : 'Settings',
    'settings.profile'     : 'Profile',
    'settings.language'    : 'Language',
    'settings.theme'       : 'Theme',
    'settings.darkMode'    : 'Dark Mode',
    'settings.lightMode'   : 'Light Mode',
    'settings.signOut'     : 'Sign Out',
    'settings.exportData'  : 'Export to Sheets',
    'settings.account'     : 'Account',
    'settings.designation' : 'Designation',
    'settings.pno'         : 'P. No.',
    'settings.changePass'  : 'Change Password',

    'status.open'          : 'OPEN',
    'status.investigating' : 'INVESTIGATING',
    'status.actionTaken'   : 'ACTION TAKEN',
    'status.closed'        : 'CLOSED',
    'severity.critical'    : 'CRITICAL',
    'severity.high'        : 'HIGH',
    'severity.medium'      : 'MEDIUM',
    'severity.low'         : 'LOW',

    'msg.savedLocal'       : 'Saved locally',
    'msg.savedSheets'      : 'synced to server',
    'msg.willSync'         : 'Will sync when online',
    'msg.exportSuccess'    : 'Exported successfully',
    'msg.networkError'     : 'Network error — try again',
    'msg.permissionDenied' : 'Permission denied',

    // WSA-13 categories
    'wsa.fallFromHeight'   : 'Fall from Height',
    'wsa.slipFall'         : 'Slip / Fall',
    'wsa.hitCaughtPressed' : 'Hit / Caught / Pressed',
    'wsa.hotMetalSlag'     : 'Hot Metal / Slag',
    'wsa.electrical'       : 'Electrical',
    'wsa.gas'              : 'Gas',
    'wsa.explosion'        : 'Explosion',
    'wsa.machinery'        : 'Machinery',
    'wsa.transport'        : 'Transport',
    'wsa.confinedSpace'    : 'Confined Space',
    'wsa.chemical'         : 'Chemical',
    'wsa.ergonomic'        : 'Ergonomic',
    'wsa.other'            : 'Other',

    // Dashboard WSA chart
    'dashboard.wsaChart'       : 'WSA-13 Cases',
    'dashboard.entireSail'     : 'Entire SAIL',
    'dashboard.selectPlant'    : 'Select Plant',
    'dashboard.wsaCategories'  : 'WSA Categories',

    // ── Device permissions + My Profile (2026-10-30) ──
    'perm.camera'          : 'Camera',
    'perm.microphone'      : 'Microphone',
    'perm.location'        : 'Location',
    'perm.camera.why'      : 'Take photos for AI Scan and Near Miss reports',
    'perm.microphone.why'  : 'Speak instead of typing (voice input)',
    'perm.location.why'    : 'Tag reports with where the photo was taken',
    'perm.sheetTitle'      : 'Allow camera, microphone and location',
    'perm.sheetBody'       : 'Safety Lens uses these to capture hazards quickly. Your device will ask you once for each one you keep ticked.',
    'perm.sheetFoot'       : 'You will not be asked again. You can change this any time in My Profile.',
    'perm.notNow'          : 'Not now',
    'perm.continue'        : 'Continue',
    'perm.alreadyAllowed'  : 'Already allowed on this device',
    'perm.someBlocked'     : 'Not allowed: {list}. You can change this in My Profile.',
    'perm.offTitle'        : '{feature} is turned off',
    'perm.offBody'         : 'You turned off {feature} for Safety Lens. Turn it on now? You can change this again in My Profile.',
    'perm.keepOff'         : 'Keep off',
    'perm.turnOn'          : 'Turn on',
    'perm.blockedTitle'    : '{feature} is blocked',
    'perm.blockedApp'      : '{feature} is blocked in your phone settings. Open Settings > Permissions and allow {feature} for Safety Lens.',
    'perm.blockedWeb'      : '{feature} is blocked for this website. Tap the padlock (or "aA") next to the address, open site settings, and allow {feature}. Then try again.',
    'perm.openSettings'    : 'Open settings',
    'perm.section'         : 'Device permissions',
    'perm.deviceSays'      : 'This device: {state}',
    'perm.state.allowed'   : 'Allowed',
    'perm.state.denied'    : 'Not allowed',
    'perm.state.blocked'   : 'Blocked (change in settings)',
    'perm.state.notAsked'  : 'Not asked yet',
    'perm.state.unknown'   : 'Will ask when used',
    'perm.helpApp'         : 'The switch is your choice in Safety Lens. If something is blocked, allow it in your phone settings.',
    'perm.helpWeb'         : 'The switch is your choice in Safety Lens. The browser keeps its own setting for this site; on iPhone Safari it may ask again unless the site is set to Allow.',
    'profile.title'        : 'My Profile',
    'profile.open'         : 'My Profile',
    'profile.fromHr'       : 'From the employee records',
    'profile.fromHrNote'   : 'These come from the HR employee list. Ask your admin to correct them.',
    'profile.yourDetails'  : 'Your contact and job details',
    'profile.name'         : 'Name',
    'profile.pno'          : 'P.No',
    'profile.grade'        : 'Grade',
    'profile.plant'        : 'Plant',
    'profile.mobile'       : 'Mobile number',
    'profile.email'        : 'Email',
    'profile.designation'  : 'Designation',
    'profile.department'   : 'Department',
    'profile.unit'         : 'Unit / section',
    'profile.pickDepartment': 'Choose from the list',
    'profile.keptNote'     : 'Your changes are kept when the HR list is refreshed.',
    'profile.saved'        : 'Profile saved',
    'profile.savedUnprotected': 'Profile saved. Note: the next HR list refresh may overwrite it until the admin runs the profile update on the server.',
    'profile.saveFailed'   : 'Could not save: {err}',
  };

  // ──────────────────────────────────────────────────────────────
  //  HINDI (हिंदी)
  // ──────────────────────────────────────────────────────────────
  static const Map<String, String> _hi = {
    'app.name'             : 'सेल सेफ्टी लेंस',
    'app.tagline'          : 'AI सुरक्षा प्लेटफ़ॉर्म',

    'common.save'          : 'सहेजें',
    'common.cancel'        : 'रद्द करें',
    'common.close'         : 'बंद करें',
    'common.delete'        : 'हटाएँ',
    'common.edit'          : 'संपादित करें',
    'common.add'           : 'जोड़ें',
    'common.submit'        : 'जमा करें',
    'common.export'        : 'निर्यात',
    'common.search'        : 'खोजें',
    'common.filter'        : 'फ़िल्टर',
    'common.refresh'       : 'रिफ्रेश',
    'common.sync'          : 'सिंक',
    'common.loading'       : 'लोड हो रहा है…',
    'common.success'       : 'सफल',
    'common.failed'        : 'विफल',
    'common.yes'           : 'हाँ',
    'common.no'            : 'नहीं',
    'common.ok'            : 'ठीक है',
    'common.back'          : 'वापस',
    'common.next'          : 'अगला',
    'common.continue'      : 'जारी रखें',
    'common.retry'         : 'पुनः प्रयास',

    'tab.home'             : 'होम',
    'tab.aiScan'           : 'AI स्कैन',
    'tab.nearMiss'         : 'नियर मिस',
    'tab.askAi'            : 'AI से पूछें',
    'tab.reports'          : 'रिपोर्ट',

    'home.welcome'         : 'स्वागत है',
    'home.dashboard'       : 'सुरक्षा डैशबोर्ड',
    'home.totalCases'      : 'कुल मामले',
    'home.openCases'       : 'खुले',
    'home.closedCases'     : 'बंद',
    'home.criticalCases'   : 'गंभीर',
    'home.thisMonth'       : 'इस माह',
    'home.thisWeek'        : 'इस सप्ताह',
    'home.today'           : 'आज',
    'home.quickActions'    : 'त्वरित कार्य',
    'home.recentActivity'  : 'हालिया गतिविधि',
    'home.safetyStats'     : 'सुरक्षा आँकड़े',
    'home.byPlant'         : 'संयंत्रवार',
    'home.bySeverity'      : 'गंभीरता के अनुसार',
    'home.daysSinceLti'    : 'LTI के बाद दिन',
    'home.safetyScore'     : 'सुरक्षा स्कोर',
    'home.viewAll'         : 'सभी देखें',
    'home.noData'          : 'अभी तक कोई घटना नहीं',
    'home.startScan'       : 'AI स्कैन शुरू करें',
    'home.reportNearMiss'  : 'नियर मिस रिपोर्ट',
    'home.viewReports'     : 'रिपोर्ट देखें',
    'home.askExpert'       : 'विशेषज्ञ से पूछें',
    'home.scanSop'         : 'SOP / SMP स्कैन करें',
    'home.askDocument'     : 'दस्तावेज़ से पूछें',
    'home.greeting.morning': 'सुप्रभात',
    'home.greeting.afternoon': 'नमस्कार',
    'home.greeting.evening': 'शुभ संध्या',
    'home.weeklyTrend'     : 'साप्ताहिक प्रवृत्ति',
    'home.topHazards'      : 'मुख्य खतरे',

    'aiScan.title'         : 'MAMR',
    'aiScan.subtitle'      : 'मेरा क्षेत्र, मेरी ज़िम्मेदारी',
    'aiScan.capture'       : 'फोटो',
    'aiScan.aiScan'        : 'AI स्कैन',
    'aiScan.review'        : 'समीक्षा',
    'aiScan.save'          : 'सहेजें',
    'aiScan.mitigate'      : 'निवारण',
    'aiScan.takePhoto'     : 'कार्यस्थल की फोटो लें',
    'aiScan.aiDetects'     : 'AI ख़तरों का पता लगाता है और फोटो पर अंकित करता है',
    'aiScan.camera'        : 'कैमरा',
    'aiScan.gallery'       : 'गैलरी',
    'aiScan.analyzing'     : 'फोटो का विश्लेषण…',
    'aiScan.summary'       : 'सारांश',
    'aiScan.hazardAnalysis': 'ख़तरा विश्लेषण',
    'aiScan.overallRisk'   : 'समग्र जोखिम',
    'aiScan.confidence'    : 'विश्वास',
    'aiScan.savedToSheets' : 'गूगल शीट में सहेजा गया',
    'aiScan.newScan'       : 'नया',
    'aiScan.pdf'           : 'PDF',
    'aiScan.howItWorks'    : 'AI स्कैन कैसे काम करता है',

    'nearMiss.title'       : 'नियर मिस / असुरक्षित स्थिति',
    'nearMiss.brief'       : 'संक्षिप्त विवरण',
    'nearMiss.briefHint'   : 'क्या हुआ? (आवाज़ या लिख कर)',
    'nearMiss.plant'       : 'संयंत्र',
    'nearMiss.dept'        : 'विभाग',
    'nearMiss.location'    : 'स्थान',
    'nearMiss.severity'    : 'गंभीरता',
    'nearMiss.people'      : 'शामिल व्यक्ति',
    'nearMiss.description' : 'विस्तृत विवरण',
    'nearMiss.action'      : 'तुरंत की गई कार्यवाही',
    'nearMiss.uploadImage' : 'फोटो अपलोड',
    'nearMiss.submit'      : 'रिपोर्ट जमा करें',
    'nearMiss.submitExport': 'जमा + PDF',
    'nearMiss.recording'   : 'सुन रहा है…',
    'nearMiss.tapToTalk'   : 'बोलने के लिए माइक दबाएँ',

    'reports.title'        : 'रिपोर्ट्स',
    'reports.heading'      : 'विश्लेषण और रिपोर्ट',
    'reports.tab.overview' : 'अवलोकन',
    'reports.tab.log'      : 'लॉग',
    'reports.tab.analysis' : 'विश्लेषण',
    'reports.tab.plantWise': 'प्लांट अनुसार',
    'reports.all'          : 'सभी',
    'reports.open'         : 'खुले',
    'reports.closed'       : 'बंद',
    'reports.critical'     : 'गंभीर',
    'reports.high'         : 'उच्च',
    'reports.medium'       : 'मध्यम',
    'reports.low'          : 'निम्न',
    'reports.plant'        : 'संयंत्र / इकाई',
    'reports.byPlant'      : 'संयंत्र अनुसार फ़िल्टर',
    'reports.allPlants'    : 'सभी संयंत्र',
    'reports.export'       : 'PDF निर्यात',
    'reports.exportSheets' : 'शीट में खोलें',
    'reports.noReports'    : 'कोई रिपोर्ट नहीं',
    'reports.sortBy'       : 'क्रमबद्ध करें',
    'reports.date'         : 'दिनांक',
    'reports.severity'     : 'गंभीरता',
    'reports.score'        : 'जोखिम स्कोर',
    'reports.status'       : 'स्थिति',

    'settings.title'       : 'सेटिंग्स',
    'settings.profile'     : 'प्रोफ़ाइल',
    'settings.language'    : 'भाषा',
    'settings.theme'       : 'थीम',
    'settings.darkMode'    : 'डार्क मोड',
    'settings.lightMode'   : 'लाइट मोड',
    'settings.signOut'     : 'साइन आउट',
    'settings.exportData'  : 'शीट में निर्यात',
    'settings.account'     : 'खाता',
    'settings.designation' : 'पदनाम',
    'settings.pno'         : 'पी. नं.',
    'settings.changePass'  : 'पासवर्ड बदलें',

    'status.open'          : 'खुला',
    'status.investigating' : 'जाँच',
    'status.actionTaken'   : 'कार्यवाही',
    'status.closed'        : 'बंद',
    'severity.critical'    : 'गंभीर',
    'severity.high'        : 'उच्च',
    'severity.medium'      : 'मध्यम',
    'severity.low'         : 'निम्न',

    'msg.savedLocal'       : 'स्थानीय रूप से सहेजा गया',
    'msg.savedSheets'      : 'सर्वर पर सिंक',
    'msg.willSync'         : 'ऑनलाइन होने पर सिंक होगा',
    'msg.exportSuccess'    : 'निर्यात सफल',
    'msg.networkError'     : 'नेटवर्क त्रुटि — पुनः प्रयास',
    'msg.permissionDenied' : 'अनुमति अस्वीकृत',

    // WSA-13 categories
    'wsa.fallFromHeight'   : 'ऊँचाई से गिरना',
    'wsa.slipFall'         : 'फिसलना / गिरना',
    'wsa.hitCaughtPressed' : 'दबना / टकराना',
    'wsa.hotMetalSlag'     : 'गर्म धातु / स्लैग',
    'wsa.electrical'       : 'विद्युत',
    'wsa.gas'              : 'गैस',
    'wsa.explosion'        : 'विस्फोट',
    'wsa.machinery'        : 'मशीनरी',
    'wsa.transport'        : 'परिवहन',
    'wsa.confinedSpace'    : 'सीमित स्थान',
    'wsa.chemical'         : 'रासायनिक',
    'wsa.ergonomic'        : 'शारीरिक मुद्रा',
    'wsa.other'            : 'अन्य',

    'dashboard.wsaChart'       : 'WSA-13 मामले',
    'dashboard.entireSail'     : 'सम्पूर्ण SAIL',
    'dashboard.selectPlant'    : 'संयंत्र चुनें',
    'dashboard.wsaCategories'  : 'WSA श्रेणियाँ',

    // ── Device permissions + My Profile (2026-10-30) ──
    'perm.camera'          : 'कैमरा',
    'perm.microphone'      : 'माइक्रोफ़ोन',
    'perm.location'        : 'लोकेशन',
    'perm.camera.why'      : 'AI स्कैन और नियर मिस रिपोर्ट के लिए फ़ोटो लेना',
    'perm.microphone.why'  : 'टाइप करने के बजाय बोलकर लिखना',
    'perm.location.why'    : 'रिपोर्ट में फ़ोटो की जगह जोड़ना',
    'perm.sheetTitle'      : 'कैमरा, माइक्रोफ़ोन और लोकेशन की अनुमति दें',
    'perm.sheetBody'       : 'सेफ्टी लेंस इनसे खतरों को जल्दी दर्ज करता है। जिन पर टिक लगा रहेगा, उनके लिए आपका डिवाइस एक बार पूछेगा।',
    'perm.sheetFoot'       : 'यह दोबारा नहीं पूछा जाएगा। आप इसे कभी भी "मेरी प्रोफ़ाइल" में बदल सकते हैं।',
    'perm.notNow'          : 'अभी नहीं',
    'perm.continue'        : 'आगे बढ़ें',
    'perm.alreadyAllowed'  : 'इस डिवाइस पर पहले से अनुमति है',
    'perm.someBlocked'     : 'अनुमति नहीं मिली: {list}। आप इसे "मेरी प्रोफ़ाइल" में बदल सकते हैं।',
    'perm.offTitle'        : '{feature} बंद है',
    'perm.offBody'         : 'आपने सेफ्टी लेंस के लिए {feature} बंद किया है। क्या अभी चालू करें? आप इसे "मेरी प्रोफ़ाइल" में फिर बदल सकते हैं।',
    'perm.keepOff'         : 'बंद रखें',
    'perm.turnOn'          : 'चालू करें',
    'perm.blockedTitle'    : '{feature} ब्लॉक है',
    'perm.blockedApp'      : 'फ़ोन की सेटिंग में {feature} ब्लॉक है। Settings > Permissions खोलकर सेफ्टी लेंस के लिए {feature} की अनुमति दें।',
    'perm.blockedWeb'      : 'इस वेबसाइट के लिए {feature} ब्लॉक है। पते के पास ताले (या "aA") पर टैप करें, साइट सेटिंग खोलें और {feature} की अनुमति दें। फिर दोबारा कोशिश करें।',
    'perm.openSettings'    : 'सेटिंग खोलें',
    'perm.section'         : 'डिवाइस अनुमतियाँ',
    'perm.deviceSays'      : 'यह डिवाइस: {state}',
    'perm.state.allowed'   : 'अनुमति है',
    'perm.state.denied'    : 'अनुमति नहीं',
    'perm.state.blocked'   : 'ब्लॉक (सेटिंग में बदलें)',
    'perm.state.notAsked'  : 'अभी पूछा नहीं गया',
    'perm.state.unknown'   : 'उपयोग के समय पूछा जाएगा',
    'perm.helpApp'         : 'स्विच सेफ्टी लेंस में आपकी पसंद है। अगर कुछ ब्लॉक है, तो फ़ोन की सेटिंग में अनुमति दें।',
    'perm.helpWeb'         : 'स्विच सेफ्टी लेंस में आपकी पसंद है। ब्राउज़र इस साइट के लिए अपनी अलग सेटिंग रखता है; iPhone Safari दोबारा पूछ सकता है जब तक साइट को "Allow" न किया जाए।',
    'profile.title'        : 'मेरी प्रोफ़ाइल',
    'profile.open'         : 'मेरी प्रोफ़ाइल',
    'profile.fromHr'       : 'कर्मचारी रिकॉर्ड से',
    'profile.fromHrNote'   : 'ये HR कर्मचारी सूची से आते हैं। सुधार के लिए एडमिन से कहें।',
    'profile.yourDetails'  : 'आपका संपर्क और कार्य विवरण',
    'profile.name'         : 'नाम',
    'profile.pno'          : 'P.No',
    'profile.grade'        : 'ग्रेड',
    'profile.plant'        : 'संयंत्र',
    'profile.mobile'       : 'मोबाइल नंबर',
    'profile.email'        : 'ईमेल',
    'profile.designation'  : 'पदनाम',
    'profile.department'   : 'विभाग',
    'profile.unit'         : 'यूनिट / सेक्शन',
    'profile.pickDepartment': 'सूची से चुनें',
    'profile.keptNote'     : 'HR सूची अपडेट होने पर भी आपके बदलाव बने रहेंगे।',
    'profile.saved'        : 'प्रोफ़ाइल सहेजी गई',
    'profile.savedUnprotected': 'प्रोफ़ाइल सहेजी गई। ध्यान दें: जब तक एडमिन सर्वर पर प्रोफ़ाइल अपडेट नहीं चलाते, अगली HR सूची इसे बदल सकती है।',
    'profile.saveFailed'   : 'सहेजा नहीं जा सका: {err}',
  };
}
