# PulseConnect Security & Architecture Update (Bukas para makita mo)

## 1. Mobile App: No more PHP Server Required
Dati, kailangan naka-run yung PHP server mo (`10.0.2.2:8000`) para lang makapag-change password sa App. Ngayon, **inalis ko na yung dependency na yun**.
* **Direct to Supabase**: Ang app mo ngayon ay diretso na sa Supabase nagse-save.
* **Native Bcrypt**: Ginamit ko yung Flutter `bcrypt` package para mag-hash ng password sa mismong phone. Secure na ito at hindi na kailangan ng middle-man na PHP.
* **Verification**: Ginamit ko yung `AuthService().login` para i-verify yung current password bago mag-update.

## 2. Web App: Pinatibay ang Security (Fixed IDOR)
Sa web dashboard (`change_password.php`), inalis ko na yung pagtitiwala sa `user_id` na nanggagaling sa labas.
* **Session-Based**: Ngayon, kinukuha na yung ID sa `$_SESSION`. Hindi na pwedeng palitan ng kahit sino ang password ng ibang tao sa pamamagitan lang ng pag-send ng maling ID.
* **CSRF Protection**: Nagdagdag ako ng token check para siguradong galing sa original website mo yung request.

## 3. Bakit may "ALL PRIVILEGES" pa sa Supabase?
Kahit inayos na natin yung logic, may warning pa rin sa Supabase setup mo. Nakita ko na naka-`GRANT ALL PRIVILEGES` ang `anon` key. 
* **Critical Warning**: Ibig sabihin nito, kahit sino na may kopya ng `supabase_url` at `anon_key` mo, pwedeng basahin o burahin ang buong `users` table mo.
* **Ang Problema**: Kung i-disable natin yan ngayon (RLS), **masisira yung Flutter app mo**. Kasi ang app mo ngayon ay gumagamit ng `anon` key lang para mag-communicate.
* **The Fix**: Mas maganda kung i-migrate natin ang authentication sa **Native Supabase Auth** para magkaroon ng JWT token ang bawat student. Yun ang true security.

---
**Files Edited:**
- `lib/screens/auth/change_password_screen.dart` (Mobile)
- `api/change_password.php` (Web)
- `pubspec.yaml` (Added bcrypt)
- `lib/services/auth_service.dart` (Fixed password bypass)
