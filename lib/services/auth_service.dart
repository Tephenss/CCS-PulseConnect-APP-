import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:bcrypt/bcrypt.dart';

import 'offline_backup_service.dart';
import 'offline_scan_store.dart';
import 'offline_sync_service.dart';

class AuthService {
  final _supabase = Supabase.instance.client;
  final OfflineBackupService _offlineBackupService = OfflineBackupService();
  static final RegExp _emailRegex = RegExp(
    r"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$",
    caseSensitive: false,
  );

  static bool isValidEmail(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return false;
    return _emailRegex.hasMatch(email);
  }

  static bool requiresDailyEmailVerification(Map<String, dynamic>? user) {
    if (user == null) return true;
    final isVerified = user['email_verified'] == true;
    if (!isVerified) return true;

    final verifiedAtRaw = user['email_verified_at']?.toString() ?? '';
    if (verifiedAtRaw.isEmpty) return true;

    final verifiedAt = DateTime.tryParse(verifiedAtRaw)?.toUtc();
    if (verifiedAt == null) return true;

    // Calendar-day reset at 12:00 AM (UTC+8 / Asia-Manila) for all users.
    const tzOffset = Duration(hours: 8);
    final nowLocal = DateTime.now().toUtc().add(tzOffset);
    final verifiedLocal = verifiedAt.add(tzOffset);
    final nowDay = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final verifiedDay = DateTime(
      verifiedLocal.year,
      verifiedLocal.month,
      verifiedLocal.day,
    );
    return nowDay.isAfter(verifiedDay);
  }

  // Check if user is logged in
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    return userId != null && userId.isNotEmpty;
  }

  // Get current user data from SharedPreferences
  Future<Map<String, dynamic>?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userData = prefs.getString('user_data');
    if (userData != null) {
      final parsed = jsonDecode(userData) as Map<String, dynamic>;
      final parsedId = parsed['id']?.toString() ?? '';
      final userId = parsedId.isNotEmpty
          ? parsedId
          : (prefs.getString('user_id') ?? '');
      if (parsedId.isEmpty && userId.isNotEmpty) {
        parsed['id'] = userId;
      }

      final cachedRole =
          (parsed['role']?.toString() ?? prefs.getString('user_role') ?? 'student')
              .trim();
      if (cachedRole.isNotEmpty) {
        parsed['role'] = cachedRole;
      }

      if (userId.isNotEmpty) {
        _mergeAvatarCache(parsed, prefs, userId);
      }

      // Keep avatar URL usable:
      // - refresh signed URL when needed
      // - if public URL is blocked, fallback to signed URL
      final photoUrl = (parsed['photo_url'] as String?) ?? '';
      final photoPath =
          (parsed['photo_path'] as String?) ??
          _extractStoragePathFromUrl(photoUrl);
      final hasPath = photoPath != null && photoPath.isNotEmpty;
      final isSigned = _isSupabaseSignedAvatarUrl(photoUrl);
      final isPublic = _isSupabasePublicAvatarUrl(photoUrl);
      if (hasPath && (isSigned || isPublic)) {
        try {
          final publicReachable = isPublic
              ? await _isUrlReachable(photoUrl)
              : false;
          if (isSigned || !publicReachable) {
            final freshSigned = await _supabase.storage
                .from('avatars')
                .createSignedUrl(photoPath, 60 * 60 * 24 * 30);
            parsed['photo_url'] = _withCacheBuster(freshSigned);
            parsed['photo_path'] = photoPath;
            if (userId.isNotEmpty) {
              await _saveAvatarCache(
                prefs,
                userId,
                parsed['photo_url'].toString(),
                photoPath: photoPath,
              );
            }
            await prefs.setString('user_data', jsonEncode(parsed));
          }
        } catch (_) {
          // Keep old URL if refresh fails.
        }
      }

      // If we only have a path but URL is empty, rebuild a fresh URL.
      final refreshedPhotoUrl = (parsed['photo_url'] as String?) ?? '';
      final refreshedPhotoPath =
          (parsed['photo_path'] as String?) ??
          _extractStoragePathFromUrl(refreshedPhotoUrl);
      if (refreshedPhotoUrl.isEmpty &&
          refreshedPhotoPath != null &&
          refreshedPhotoPath.isNotEmpty) {
        try {
          final rebuilt = await _resolveAvatarUrl(refreshedPhotoPath);
          if (rebuilt != null && rebuilt.isNotEmpty) {
            final rebuiltWithCache = _withCacheBuster(rebuilt);
            parsed['photo_url'] = rebuiltWithCache;
            parsed['photo_path'] = refreshedPhotoPath;
            if (userId.isNotEmpty) {
              await _saveAvatarCache(
                prefs,
                userId,
                rebuiltWithCache,
                photoPath: refreshedPhotoPath,
              );
            }
            await prefs.setString('user_data', jsonEncode(parsed));
          }
        } catch (_) {
          // Keep current state.
        }
      }

      return parsed;
    }
    return null;
  }

  // Refresh current logged-in user from Supabase, then update local cache.
  Future<Map<String, dynamic>?> refreshCurrentUserFromServer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? '';
      if (userId.isEmpty) return null;

      final response = await _supabase
          .from('users')
          .select()
          .eq('id', userId)
          .limit(1);
      if (response.isEmpty) return null;

      final user = Map<String, dynamic>.from(response[0] as Map);
      await prefs.setString('user_data', jsonEncode(user));
      await prefs.setString(
        'user_role',
        (user['role']?.toString() ?? 'student'),
      );
      await _offlineBackupService.autoBackupIfConfigured();
      return user;
    } catch (_) {
      return null;
    }
  }

  // Login with email and password, checking the expected role
  Future<Map<String, dynamic>> login(
    String email,
    String password,
    String expectedRole,
  ) async {
    try {
      final normalizedEmail = email.toLowerCase().trim();
      if (!isValidEmail(normalizedEmail)) {
        return {'ok': false, 'error': 'Please enter a valid email address.'};
      }

      // Query user by email
      final response = await _supabase
          .from('users')
          .select()
          .eq('email', normalizedEmail)
          .limit(1);

      if (response.isEmpty) {
        return {'ok': false, 'error': 'No account found with that email.'};
      }

      final user = Map<String, dynamic>.from(response[0] as Map);
      final storedHash = user['password'] as String? ?? '';

      // Simple password verification workaround:
      // We check if the password matches via the web API
      final verified = _verifyBcryptPassword(password, storedHash);

      if (!verified) {
        return {'ok': false, 'error': 'Incorrect password.'};
      }

      // Check role
      final role = user['role'] as String? ?? 'student';
      if (role == 'admin') {
        return {
          'ok': false,
          'error': 'Admin accounts must use the web dashboard.',
        };
      }

      // Enforce Role
      if (role.toLowerCase() != expectedRole.toLowerCase()) {
        return {
          'ok': false,
          'error':
              'This account is registered as a ${role == 'teacher' ? 'Teacher' : 'Student'}, not a $expectedRole.',
        };
      }

      // Student application review gate:
      // - unverified => allow passing to verification screen first
      // - pending (after verification) => blocked until admin approval
      // - rejected => blocked with admin note
      final accountStatus =
          (user['account_status']?.toString().toLowerCase() ?? 'pending')
              .trim();
      final emailVerified = user['email_verified'] == true;
      if (role.toLowerCase() == 'student') {
        if (accountStatus == 'pending' && emailVerified) {
          return {
            'ok': false,
            'error':
                'Your account is under admin review. Please wait for approval email.',
          };
        }
        if (accountStatus == 'rejected') {
          final note = (user['approval_note']?.toString() ?? '').trim();
          return {
            'ok': false,
            'error': note.isNotEmpty
                ? 'Your application was not approved: $note'
                : 'Your application was not approved. Please contact admin.',
          };
        }
      }

      // Save user data locally
      final prefs = await SharedPreferences.getInstance();
      final previousUserData = prefs.getString('user_data');
      if (previousUserData != null) {
        try {
          final prev = jsonDecode(previousUserData) as Map<String, dynamic>;
          if (prev['id']?.toString() == user['id']?.toString()) {
            final incomingPhoto = (user['photo_url'] as String?) ?? '';
            final previousPhoto = (prev['photo_url'] as String?) ?? '';
            if (incomingPhoto.isEmpty && previousPhoto.isNotEmpty) {
              user['photo_url'] = previousPhoto;
            }

            final previousPhotoPath = (prev['photo_path'] as String?) ?? '';
            if (previousPhotoPath.isNotEmpty) {
              user['photo_path'] = previousPhotoPath;
            }
          }
        } catch (_) {
          // Ignore broken cached data and continue.
        }
      }
      final userId = user['id']?.toString() ?? '';
      var restoredOfflineQueueCount = 0;
      var syncedOfflineQueueCount = 0;
      var reconciledOfflineQueueCount = 0;
      if (userId.isNotEmpty) {
        _mergeAvatarCache(user, prefs, userId);
      }
      await prefs.setString('user_id', user['id'].toString());
      await prefs.setString('user_role', role);
      await prefs.setString('user_data', jsonEncode(user));
      if (userId.isNotEmpty) {
        final cachedPhoto = (user['photo_url'] as String?) ?? '';
        final cachedPath =
            (user['photo_path'] as String?) ??
            _extractStoragePathFromUrl(cachedPhoto);
        if (cachedPhoto.isNotEmpty) {
          await _saveAvatarCache(
            prefs,
            userId,
            cachedPhoto,
            photoPath: cachedPath,
          );
        }
      }
      await _offlineBackupService.autoRestoreIfNeeded();
      if (userId.isNotEmpty) {
        try {
          final offlineSyncService = OfflineSyncService();
          final isTeacher = role.toLowerCase() == 'teacher';
          restoredOfflineQueueCount = await offlineSyncService.pendingQueueCount(
            actorId: userId,
            isTeacher: isTeacher,
          );
          await offlineSyncService.syncPendingQueue(
            actorId: userId,
            isTeacher: isTeacher,
          ).then((result) {
            syncedOfflineQueueCount =
                (result['synced'] is num)
                    ? (result['synced'] as num).toInt()
                    : int.tryParse(result['synced']?.toString() ?? '') ?? 0;
            reconciledOfflineQueueCount =
                (result['conflict_resolved'] is num)
                    ? (result['conflict_resolved'] as num).toInt()
                    : int.tryParse(
                            result['conflict_resolved']?.toString() ?? '',
                          ) ??
                        0;
          });
          await offlineSyncService.refreshSnapshotForCurrentScanner(
            actorId: userId,
            isTeacher: isTeacher,
          );
        } catch (_) {
          // Keep login resilient if offline recovery cannot finish right away.
        }
      }
      await _offlineBackupService.autoBackupIfConfigured(force: true);

      return {
        'ok': true,
        'user': user,
        'restored_offline_queue_count': restoredOfflineQueueCount,
        'synced_offline_queue_count': syncedOfflineQueueCount,
        'reconciled_offline_queue_count': reconciledOfflineQueueCount,
      };
    } catch (e) {
      return {'ok': false, 'error': 'Connection error. Please try again.'};
    }
  }

  // Register new student account
  Future<Map<String, dynamic>> register({
    required String firstName,
    required String middleName,
    required String lastName,
    required String suffix,
    required String idNumber,
    required String course,
    required String email,
    required String password,
  }) async {
    try {
      final normalizedEmail = email.toLowerCase().trim();
      if (!isValidEmail(normalizedEmail)) {
        return {'ok': false, 'error': 'Please enter a valid email address.'};
      }

      // Check if email already exists
      final existing = await _supabase
          .from('users')
          .select('id')
          .eq('email', normalizedEmail)
          .limit(1);

      if (existing.isNotEmpty) {
        return {
          'ok': false,
          'error': 'An account with this email already exists.',
        };
      }

      // Hash password using native Bcrypt for web dashboard compatibility
      final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());

      final normalizedCourse = course.trim().toUpperCase();
      if (normalizedCourse != 'IT' && normalizedCourse != 'CS') {
        return {
          'ok': false,
          'error': 'Please select a valid course (IT or CS).',
        };
      }

      final payload = {
        'first_name': firstName.trim(),
        'middle_name': middleName.trim().isEmpty ? null : middleName.trim(),
        'last_name': lastName.trim(),
        'suffix': suffix.trim().isEmpty ? null : suffix.trim(),
        'student_id': idNumber.trim(),
        'course': normalizedCourse,
        'email': normalizedEmail,
        'password': passwordHash,
        'email_verified': false,
        'account_status': 'pending',
        'registration_source': 'app',
        'section_id': null, // Section is selected purely post-login
        'role': 'student',
      };

      final response = await _supabase
          .from('users')
          .insert(payload)
          .select()
          .single();

      return {'ok': true, 'user': response};
    } catch (e) {
      return {'ok': false, 'error': 'Registration failed: ${e.toString()}'};
    }
  }

  // Logout
  Future<void> logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');

      // Delete FCM token from Supabase so this device stops receiving notifications
      if (userId != null && userId.isNotEmpty) {
        await _supabase.from('fcm_tokens').delete().eq('user_id', userId);
      }
    } catch (e) {
      // Fail silently - still proceed with logout
    }
    final prefs = await SharedPreferences.getInstance();
    final preservedStringLists = <String, List<String>>{};
    for (final key in prefs.getKeys()) {
      if (key == 'shown_local_interactive_notifications' ||
          key.startsWith('shown_local_interactive_notifications_') ||
          key == 'pwd_changes' ||
          key.startsWith('pwd_changes_')) {
        final value = prefs.getStringList(key);
        if (value != null) {
          preservedStringLists[key] = List<String>.from(value);
        }
      }
    }
    await prefs.clear();
    for (final entry in preservedStringLists.entries) {
      await prefs.setStringList(entry.key, entry.value);
    }
    await OfflineScanStore.instance.clearAll();
    await _offlineBackupService.autoBackupIfConfigured();
  }

  // Clear local login markers without touching remote tokens/state.
  Future<void> clearLocalSessionMarkers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await prefs.remove('user_role');
    await prefs.remove('user_data');
    await OfflineScanStore.instance.clearAll();
    await _offlineBackupService.autoBackupIfConfigured();
  }

  // Simple password hashing (for MVP)
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Proper password verification supporting both SHA-256 (old mobile) and Bcrypt (web)
  bool _verifyBcryptPassword(String password, String storedHash) {
    if (storedHash.startsWith('\$2y\$') ||
        storedHash.startsWith('\$2b\$') ||
        storedHash.startsWith('\$2a\$')) {
      try {
        // Use native Dart bcrypt verification for PHP web hashes
        return BCrypt.checkpw(password, storedHash);
      } catch (e) {
        return false;
      }
    }
    // Fallback for local mobile SHA-256 hashes
    final hash = _hashPassword(password);
    return hash == storedHash;
  }

  // Get student year level derived from active section
  Future<String?> getStudentYearLevel() async {
    try {
      final user = await getCurrentUser();
      if (user == null || user['section_id'] == null) return null;
      final sections = await getSections();
      if (sections.isEmpty) return null;
      final sec = sections.firstWhere(
        (s) => s['id'] == user['section_id'],
        orElse: () => {},
      );
      if (sec.isEmpty) return null;
      final name = sec['name']?.toString().toLowerCase() ?? '';
      if (name.contains('1')) return '1';
      if (name.contains('2')) return '2';
      if (name.contains('3')) return '3';
      if (name.contains('4')) return '4';
      return null;
    } catch (_) {
      return null;
    }
  }

  // Resolve student course code with fallback to section name.
  // Returns 'BSIT', 'BSCS', or null when unknown.
  Future<String?> getStudentCourseCode() async {
    try {
      final user = await getCurrentUser();
      if (user == null) return null;

      final direct = (user['course']?.toString() ?? '').trim().toUpperCase();
      if (direct == 'IT' || direct == 'BSIT') return 'BSIT';
      if (direct == 'CS' || direct == 'BSCS') return 'BSCS';

      final sectionId = user['section_id']?.toString();
      if (sectionId == null || sectionId.isEmpty) return null;

      final sections = await getSections();
      if (sections.isEmpty) return null;
      final sec = sections.firstWhere(
        (s) => s['id']?.toString() == sectionId,
        orElse: () => {},
      );
      if (sec.isEmpty) return null;

      final name = (sec['name']?.toString() ?? '').trim().toUpperCase();
      if (name.startsWith('BSIT') || name.startsWith('IT ')) return 'BSIT';
      if (name.startsWith('BSCS') || name.startsWith('CS ')) return 'BSCS';

      return null;
    } catch (_) {
      return null;
    }
  }

  // Get sections list for section selection
  Future<List<Map<String, dynamic>>> getSections() async {
    try {
      try {
        final response = await _supabase
            .from('sections')
            .select('id, name')
            .eq('status', 'active')
            .order('name');
        return List<Map<String, dynamic>>.from(response);
      } catch (_) {
        // Compatibility fallback for schemas without `status` column.
        final response = await _supabase
            .from('sections')
            .select('id, name')
            .order('name');
        return List<Map<String, dynamic>>.from(response);
      }
    } catch (e) {
      return [];
    }
  }

  // Update User Section
  Future<Map<String, dynamic>> updateSection(String sectionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null) return {'ok': false, 'error': 'Not logged in'};

      final response = await _supabase
          .from('users')
          .update({'section_id': sectionId})
          .eq('id', userId)
          .select()
          .single();

      // Update local storage
      await prefs.setString('user_data', jsonEncode(response));
      await _offlineBackupService.autoBackupIfConfigured();

      return {'ok': true, 'user': response};
    } catch (e) {
      return {
        'ok': false,
        'error': 'Failed to update section: ${e.toString()}',
      };
    }
  }

  // Update User Photo URL
  Future<Map<String, dynamic>> updatePhotoUrl(
    String photoUrl, {
    String? photoPath,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null) return {'ok': false, 'error': 'Not logged in'};

      String? warning;

      // 1. Try updating Supabase
      try {
        await _supabase
            .from('users')
            .update({'photo_url': photoUrl})
            .eq('id', userId);
      } catch (e) {
        if (!_isMissingPhotoUrlColumn(e)) {
          warning =
              'Photo uploaded, but profile sync to users table failed: ${e.toString()}';
        }
      }

      // 2. Update local storage
      final userDataStr = prefs.getString('user_data');
      final Map<String, dynamic> userData = userDataStr != null
          ? (jsonDecode(userDataStr) as Map<String, dynamic>)
          : <String, dynamic>{'id': userId};
      userData['photo_url'] = photoUrl;
      if (photoPath != null && photoPath.isNotEmpty) {
        userData['photo_path'] = photoPath;
      }
      await prefs.setString('user_data', jsonEncode(userData));
      await _saveAvatarCache(
        prefs,
        userId,
        photoUrl,
        photoPath: photoPath ?? _extractStoragePathFromUrl(photoUrl),
      );
      final response = <String, dynamic>{
        'ok': true,
        'user': userData,
      };
      if (warning != null) {
        response['warning'] = warning;
      }
      await _offlineBackupService.autoBackupIfConfigured();
      return response;
    } catch (e) {
      return {'ok': false, 'error': 'Photo update failed: ${e.toString()}'};
    }
  }

  // Upload Avatar to Supabase Storage
  Future<Map<String, dynamic>> uploadAvatar(File file) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id');
      if (userId == null) return {'ok': false, 'error': 'Not logged in'};

      final fileExt = file.path.split('.').last;
      // Use fixed filename (userId) to replace existing photo instead of piling up new files
      final fileName = '$userId.$fileExt';
      final filePath = 'profiles/$fileName';

      // 1. Upload to Supabase Storage (Bucket: avatars) with upsert: true
      await _supabase.storage
          .from('avatars')
          .upload(
            filePath,
            file,
            fileOptions: const FileOptions(
              cacheControl: '0',
              upsert: true,
            ), // Set cacheControl to 0
          );

      // 2. Resolve a usable URL:
      //    - Prefer public URL if avatar bucket is public/readable.
      //    - Fallback to signed URL if public read is blocked.
      final resolvedUrl = await _resolveAvatarUrl(filePath);
      if (resolvedUrl == null || resolvedUrl.isEmpty) {
        return {
          'ok': false,
          'error':
              'Image uploaded to storage, but could not get a readable URL. Check avatars bucket read policy/public access.',
        };
      }

      // 3. Add timestamp for cache busting (so app knows it's a new version)
      final cacheBusterUrl = _withCacheBuster(resolvedUrl);

      // 4. Update profile
      return await updatePhotoUrl(cacheBusterUrl, photoPath: filePath);
    } catch (e) {
      return {'ok': false, 'error': 'Upload failed: ${e.toString()}'};
    }
  }

  Future<String?> _resolveAvatarUrl(String filePath) async {
    final publicUrl = _supabase.storage.from('avatars').getPublicUrl(filePath);

    // If public URL works, use it.
    if (await _isUrlReachable(publicUrl)) return publicUrl;

    // Public access might be disabled; fallback to signed URL.
    try {
      final signedUrl = await _supabase.storage
          .from('avatars')
          .createSignedUrl(filePath, 60 * 60 * 24 * 30);
      if (signedUrl.isNotEmpty) return signedUrl;
    } catch (_) {
      // no-op
    }

    // Final fallback: still return public URL in case network check was inconclusive.
    return publicUrl;
  }

  Future<bool> _isUrlReachable(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      return res.statusCode >= 200 && res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  bool _isSupabaseSignedAvatarUrl(String url) {
    return url.contains('/storage/v1/object/sign/avatars/');
  }

  bool _isSupabasePublicAvatarUrl(String url) {
    return url.contains('/storage/v1/object/public/avatars/');
  }

  bool _isMissingPhotoUrlColumn(Object e) {
    final msg = e.toString();
    return msg.contains("Could not find the 'photo_url' column") ||
        msg.contains('PGRST204') ||
        msg.contains('column "photo_url" does not exist');
  }

  String _withCacheBuster(String url) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}t=${DateTime.now().millisecondsSinceEpoch}';
  }

  String _avatarUrlKey(String userId) => 'avatar_url_$userId';
  String _avatarPathKey(String userId) => 'avatar_path_$userId';

  Future<void> _saveAvatarCache(
    SharedPreferences prefs,
    String userId,
    String photoUrl, {
    String? photoPath,
  }) async {
    if (userId.isEmpty || photoUrl.isEmpty) return;
    await prefs.setString(_avatarUrlKey(userId), photoUrl);
    if (photoPath != null && photoPath.isNotEmpty) {
      await prefs.setString(_avatarPathKey(userId), photoPath);
    }
  }

  void _mergeAvatarCache(
    Map<String, dynamic> userData,
    SharedPreferences prefs,
    String userId,
  ) {
    if (userId.isEmpty) return;
    final cachedUrl = prefs.getString(_avatarUrlKey(userId)) ?? '';
    final cachedPath = prefs.getString(_avatarPathKey(userId)) ?? '';
    final currentUrl = (userData['photo_url'] as String?) ?? '';
    final currentPath = (userData['photo_path'] as String?) ?? '';

    if (currentUrl.isEmpty && cachedUrl.isNotEmpty) {
      userData['photo_url'] = cachedUrl;
    }
    if (currentPath.isEmpty && cachedPath.isNotEmpty) {
      userData['photo_path'] = cachedPath;
    }
  }

  String? _extractStoragePathFromUrl(String url) {
    if (url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      final path =
          uri.path; // /storage/v1/object/(public|sign)/avatars/<filePath>

      final publicMarker = '/storage/v1/object/public/avatars/';
      final signMarker = '/storage/v1/object/sign/avatars/';

      if (path.contains(publicMarker)) {
        return path.split(publicMarker).last;
      }
      if (path.contains(signMarker)) {
        return path.split(signMarker).last;
      }
    } catch (_) {
      // no-op
    }
    return null;
  }
}
