class Env {
  // Production Note: You must replace this key with your actual public publishable/anon key.
  // Ensure that lib/config/env.dart is always inside .gitignore!
  static const String supabaseUrl = 'https://YOUR_PROJECT.supabase.co';
  
  static const String supabaseAnonKey = 'YOUR_SUPABASE_ANON_KEY';

  // Gemini API key used by AI Enhance Description in mobile app.
  static const String geminiApiKey = 'YOUR_GEMINI_API_KEY';

  // Public URL of your PHP backend (no trailing slash).
  // Example: https://your-domain.com
  // Set this after your web domain is live.
  static const String mobilePushApiBaseUrl = 'https://YOUR-WEB-DOMAIN';

  // Optional shared key for /api/mobile_push_dispatch.php
  // Keep empty if server-side key check is disabled.
  static const String mobilePushApiKey = 'YOUR_SHARED_KEY'; // optional but recommended
}
