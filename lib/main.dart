import 'package:flutter/material.dart'; // استيراد حزمة Flutter الأساسية لواجهة المستخدم
import 'package:get/get.dart'; // استيراد حزمة GetX لإدارة الحالة والتنقل
import 'package:flutter/foundation.dart'
    show kIsWeb; // استيراد ثوابت للتحقق من المنصة ووضع التشغيل
import 'dart:io' show Platform; // استيراد مكتبة التعامل مع نظام التشغيل
import 'package:sqflite_common_ffi/sqflite_ffi.dart'; // استيراد مكتبة قواعد البيانات للديسكتوب
import 'package:firebase_core/firebase_core.dart'; // استيراد المكتبة الأساسية لخدمات Firebase
import 'package:cloud_firestore/cloud_firestore.dart'; // استيراد مكتبة Cloud Firestore للتعامل مع قواعد البيانات السحابية
import 'package:media_kit/media_kit.dart'; // استيراد مكتبة تشغيل الوسائط المتعددة (فيديو وصوت)

// --- استيراد الروابط والارتباطات (Bindings) ---
import 'core/bindings/initial_binding.dart'; // استيراد ملف تهيئة الخدمات عند التشغيل

// --- استيراد الشاشات (Screens) ---
import 'screens/auth/login_screen.dart'; // شاشة تسجيل الدخول
import 'screens/auth/signup_screen.dart'; // شاشة إنشاء حساب جديد
import 'screens/auth/password_reset_otp_screen.dart'; // شاشة رمز إعادة التعيين
import 'screens/auth/account_confirmation_screen.dart'; // شاشة تأكيد الحساب
import 'screens/splash_screen.dart'; // شاشة الانطلاق (الترحيب)
import 'screens/ai_chat_screen.dart'; // شاشة الدردشة بالذكاء الاصطناعي
import 'screens/settings_screen.dart'; // شاشة إعدادات المفاتيح
import 'screens/general_settings_screen.dart'; // شاشة الإعدادات العامة
import 'screens/admin_dashboard_screen.dart'; // لوحة تحكم المسؤول (الأدمن)
import 'screens/creator_profile_screen.dart'; // شاشة ملف المبدع
import 'screens/admin/users_list_screen.dart'; // شاشة قائمة المستخدمين للمدير
import 'screens/auth/edit_profile_screen.dart'; // شاشة تعديل الملف الشخصي
import 'screens/privacy_policy_screen.dart'; // شاشة سياسة الخصوصية
import 'screens/terms_of_service_screen.dart'; // شاشة شروط الخدمة
import 'screens/subscription_screen.dart'; // شاشة الاشتراكات والباقات
import 'screens/product_photography_screen.dart'; // شاشة تصوير المنتجات بالـ AI
import 'screens/catalog/product_catalog_screen.dart'; // شاشة كتالوج المنتجات لـ Meta
import 'screens/main_wrapper.dart'; // الملف الرئيسي الذي يحتوي على شريط التنقل الديناميكي

// --- استيراد المتحكمات والخدمات (Controllers & Services) ---
import 'controllers/api_controller.dart'; // متحكم التعامل مع الواجهات البرمجية
import 'services/ai_image_generation_service.dart'; // خدمة توليد الصور بالذكاء الاصطناعي

import 'package:flutter_screenutil/flutter_screenutil.dart'; // حزمة لجعل التصميم متجاوباً مع أحجام الشاشات
import 'package:responsive_framework/responsive_framework.dart';
import 'core/storage/app_storage_service.dart'; // خدمة التخزين الموحدة
import 'services/secure_storage_service.dart';
import 'services/pocketbase/scc_pocketbase_client.dart';
import 'scc_pocketbase_app.dart';
import 'theme/app_theme.dart'; // استيراد نظام الألوان والتصميم (الثيم) الخاص بالتطبيق

// 🚀 الدالة الأساسية التي تبدأ تشغيل التطبيق
Future<void> main() async {
  // التأكد من تهيئة روابط Flutter قبل البدء بأي عمليات
  WidgetsFlutterBinding.ensureInitialized();

  // A separate fully-PocketBase-backed login/catalog shell is enabled explicitly.
  // It MUST run before Firebase, GetX bindings, or legacy providers initialize.
  // The old production app remains unchanged when the build define is absent.
  if (SccPocketBaseClient.configuredUrl.isNotEmpty) {
    runApp(const SccPocketBaseApp());
    return;
  }
  
  // 🎬 تهيئة مكتبة الميديا لتشغيل الفيديوهات والتريندات (Media Kit)
  MediaKit.ensureInitialized();

  // 📂 تهيئة خدمة التخزين الموحدة (AppStorageService)
  Get.put(SecureStorageService(), permanent: true);
  await Get.putAsync(() => AppStorageService().init(), permanent: true);

  // 📂 تهيئة قاعدة بيانات SQLite للعمل على أنظمة الديسكتوب (Windows/Linux)
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit(); // تهيئة المكتبة
    databaseFactory =
        databaseFactoryFfi; // تعيين المصنع الخاص بقواعد بيانات الديسكتوب
  }

  // 🩹 رقعة استقرار لنظام ويندوز للتعامل مع معالجة الفيديو
  if (!kIsWeb && Platform.isWindows) {
    debugPrint("🩹 وضع ويندوز: استخدام بدائل FFmpeg لمعالجة الفيديو");
  }

  // 🔥 تهيئة خدمات Firebase (وضع آمن مع معالجة الأخطاء)
  bool firebaseInitialized = false;
  try {
    if (kIsWeb) {
      // 🌐 خيارات Firebase للويب (من Firebase Console > Project Settings > Web Apps)
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyAPVyg6vgYP6iJbNYMVkgD5OrpZWRGLPgU',
          appId: '1:947880578188:web:d3143bd966646695af3fa9',
          messagingSenderId: '947880578188',
          projectId: 'smartcontentcreator-d49f2',
          storageBucket: 'smartcontentcreator-d49f2.firebasestorage.app',
          authDomain: 'smartcontentcreator-d49f2.firebaseapp.com',
          measurementId: 'G-8S56GE79C9',
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
    firebaseInitialized = true;
    
    // 🛡️ تفعيل وضع Offline لـ Firestore لمنع الانهيار عند فقدان الإنترنت
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    
    debugPrint("✅ تم تهيئة Firebase بنجاح");
  } catch (e) {
    debugPrint("⚠️ فشل تهيئة Firebase (تأكد من ملفات الإعداد): $e");
  }

  // 🌍 حفظ حالة Firebase لاستخدامها في InitialBinding
  Get.put<bool>(firebaseInitialized, tag: 'firebaseInitialized', permanent: true);

  // 🛡️ معالج أخطاء عام لمنع انهيار التطبيق (يعرض رسالة بدل الشاشة البيضاء)
  FlutterError.onError = (details) {
    debugPrint("🚨 Flutter Error: ${details.exceptionAsString()}");
    debugPrint("📍 Widget: ${details.context}");
    debugPrint("📚 Library: ${details.library}");
    // هذا يطبع الـ widget tree والملف المسبب
    FlutterError.presentError(details);
  };

  // 🎯 حقن المتحكمات الأساسية فوراً لتجنب أي تأخير في الوصول للبيانات (Race Conditions)
  Get.put(ApiController(), permanent: true);
  Get.put(AiImageGenerationService(), permanent: true);

  // تشغيل التطبيق مباشرة بدون معالج المعاينة
  runApp(const SmartContentCreatorApp());
}

// 🏗️ هيكل التطبيق الرئيسي
class SmartContentCreatorApp extends StatelessWidget {
  const SmartContentCreatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    // تهيئة نظام ScreenUtil لجعل الواجهات متجاوبة
    return ScreenUtilInit(
      designSize: const Size(375, 812), // الحجم الافتراضي للتصميم (iPhone X)
      minTextAdapt: true, // تكييف النصوص تلقائياً
      splitScreenMode: true, // دعم وضع تقسيم الشاشة
      builder: (context, child) {
        // استخدام GetMaterialApp لدعم ميزات GetX كالتنقل والثيمات
        return GetMaterialApp(
          builder: (context, widget) {
            if (widget == null) return const SizedBox.shrink();
            return ResponsiveBreakpoints.builder(
              child: widget,
              breakpoints: [
                const Breakpoint(start: 0, end: 450, name: MOBILE),
                const Breakpoint(start: 451, end: 800, name: TABLET),
                const Breakpoint(start: 801, end: 1920, name: DESKTOP),
                const Breakpoint(start: 1921, end: double.infinity, name: '4K'),
              ],
            );
          },
          debugShowCheckedModeBanner:
              false, // إخفاء علامة "Debug" من أعلى الشاشة
          enableLog: true, // تفعيل سجلات GetX لرؤية الانتقالات
          logWriterCallback: (String text, {bool isError = false}) {
            debugPrint("🚀 [APP LOG]: $text");
          },
          title: 'صانع المحتوى Ai', // عنوان التطبيق

          // 🎯 تشغيل الخدمات الأساسية (Database, Auth, الخ) بمجرد فتح التطبيق
          initialBinding: InitialBinding(),

          // ✅ دعم الوضعين الفاتح والليلي بشكل ديناميكي
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeMode.dark, // الافتراضي عند أول تشغيل

          // 🔐 نقطة البداية: شاشة الـ Splash التي تقرر التوجه لشاشة الدخول أو الرئيسية
          home: const SplashScreen(),

          // 🗺️ نظام المسارات (Routes) للتنقل بين شاشات التطبيق
          getPages: [
            GetPage(
                name: '/login',
                page: () => const LoginScreen()), // مسار تسجيل الدخول
            GetPage(
                name: '/signup',
                page: () => const SignupScreen()), // مسار الاشتراك
            GetPage(
                name: '/password-reset-otp',
                page: () {
                  final email = (Get.parameters['email'] ?? '').trim();
                  return PasswordResetOtpScreen(email: email);
                }), // مسار رمز إعادة التعيين
            GetPage(
                name: '/account-confirmation',
                page: () => const AccountConfirmationScreen()), // مسار تأكيد الحساب
            GetPage(
                name: '/splash',
                page: () => const SplashScreen()), // مسار شاشة البداية

            // المسارات المحمية (تحتاج لتسجيل دخول للدخول إليها)
            GetPage(
                name: '/chat',
                page: () => const AiChatScreen()), // الدردشة الذكية
            GetPage(
                name: '/home',
                page: () => const MainWrapper()), // الرئيسية (الديناميكية)
            GetPage(
                name: '/main',
                page: () => const MainWrapper()), // المسار الرئيسي الموحد
            GetPage(
                name: '/settings',
                page: () => const GeneralSettingsScreen()), // الإعدادات العامة
            GetPage(
                name: '/api-settings',
                page: () => const SettingsScreen()), // إعدادات المفاتيح
            GetPage(
                name: '/creator-profile',
                page: () => const CreatorProfileScreen()), // بروفايل المبدع
            GetPage(
                name: '/admin',
                page: () => const AdminDashboardScreen()), // لوحة الأدمن
            GetPage(
                name: '/admin/users',
                page: () => const UsersListScreen()), // إدارة المستخدمين
            GetPage(
                name: '/edit-profile',
                page: () => const EditProfileScreen()), // تعديل الملف الشخصي
            GetPage(
                name: '/privacy',
                page: () => const PrivacyPolicyScreen()), // سياسة الخصوصية
            GetPage(
                name: '/terms',
                page: () => const TermsOfServiceScreen()), // شروط الاستخدام
            GetPage(
                name: '/subscription',
                page: () => const SubscriptionScreen()), // نظام الاشتراكات
            GetPage(
                name: '/product-photography',
                page: () =>
                    const ProductPhotographyScreen()), // تصوير المنتجات بالـ AI
            GetPage(
                name: '/catalog',
                page: () =>
                    const ProductCatalogScreen()), // كتالوج المنتجات لـ Meta
          ],
        );
      },
    );
  }
}
