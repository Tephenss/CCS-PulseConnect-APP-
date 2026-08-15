class Env {
  // Production Note: You must replace this key with your actual public publishable/anon key.
  // Ensure that lib/config/env.dart is always inside .gitignore!
  static const String supabaseUrl = 'https://YOUR_PROJECT.supabase.co';
  
  static const String supabaseAnonKey = 'YOUR_SUPABASE_ANON_KEY';

  // Hosted PHP backend (no trailing slash).
  static const String mobilePushApiBaseUrl = 'https://ccspulseconnect.com';

  // Must match MOBILE_PUSH_API_KEY in website .env on hosting.
  // REQUIRED — use a long random secret (openssl rand -hex 32). Never leave empty.
  static const String mobilePushApiKey = 'YOUR_SHARED_KEY';
}
