import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/app_cache_service.dart';
import '../../widgets/custom_loader.dart';
import 'teacher_section_students.dart';
import '../../utils/teacher_theme_utils.dart';

class TeacherSections extends StatefulWidget {
  const TeacherSections({super.key});

  @override
  State<TeacherSections> createState() => _TeacherSectionsState();
}

class _TeacherSectionsState extends State<TeacherSections> {
  final _appCacheService = AppCacheService();
  final Connectivity _connectivity = Connectivity();
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;
  List<Map<String, dynamic>> _sections = [];
  bool _usingCachedSections = false;

  @override
  void initState() {
    super.initState();
    _fetchSections();
  }

  int _extractYearLevel(String rawName) {
    if (rawName.contains('-')) {
      final parts = rawName.split('-');
      final y = parts[0].trim();
      if (y.contains('1')) return 1;
      if (y.contains('2')) return 2;
      if (y.contains('3')) return 3;
      if (y.contains('4')) return 4;
    } else {
      final match = RegExp(r'(?:BSIT SD|BSIT BA|BSCS|BSIT)\s*(\d)').firstMatch(rawName);
      if (match != null) {
        return int.tryParse(match.group(1) ?? '99') ?? 99;
      }
    }
    return 99; // Assume highest if unknown
  }

  Future<void> _fetchSections() async {
    const cacheKey = 'teacher_sections_active';
    try {
      final connectivity = await _connectivity.checkConnectivity();
      final isOffline =
          connectivity.isEmpty ||
          connectivity.every((result) => result == ConnectivityResult.none);
      if (isOffline) {
        final cached = await _appCacheService.loadJsonList(cacheKey);
        if (!mounted) return;
        setState(() {
          _sections = cached;
          _usingCachedSections = true;
          _isLoading = false;
        });
        return;
      }

      final response = await _supabase
          .from('sections')
          .select('id, name')
          .eq('status', 'active');
      final List<Map<String, dynamic>> fetched =
          List<Map<String, dynamic>>.from(response);
      
      if (mounted) {
        fetched.sort((a, b) {
          int yearA = _extractYearLevel(a['name']?.toString() ?? '');
          int yearB = _extractYearLevel(b['name']?.toString() ?? '');
          if (yearA != yearB) return yearA.compareTo(yearB);
          return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
        });

        setState(() {
          _sections = fetched;
          _usingCachedSections = false;
          _isLoading = false;
        });
      }
      await _appCacheService.saveJsonList(cacheKey, fetched);
    } catch (e) {
      final cached = await _appCacheService.loadJsonList(cacheKey);
      if (mounted) {
        setState(() {
          _sections = cached;
          _usingCachedSections = cached.isNotEmpty;
          _isLoading = false;
        });
        if (cached.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to load sections: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB), // Very light gray background
      body: RefreshIndicator(
        onRefresh: _fetchSections,
        color: TeacherThemeUtils.primary,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
          // App Bar Header
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: TeacherThemeUtils.chromeGradient,
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(28),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Class Sections',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'View the list of active sections synced from the Admin.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.view_module_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${_sections.length} Active Sections',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.95),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Content Area
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(
                child: PulseConnectLoader(),
              ),
            )
          else if (_sections.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(Icons.groups_rounded, size: 40, color: Colors.grey.shade300),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _usingCachedSections
                          ? 'No cached sections found'
                          : 'No sections exist',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _usingCachedSections
                          ? 'Reconnect once to refresh the latest sections.'
                          : 'Sections added by the Admin will appear here.',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.98,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final section = _sections[index];
                    return _buildSectionCard(
                      section['id']?.toString() ?? '',
                      section['name'] as String? ?? 'Unknown',
                    );
                  },
                  childCount: _sections.length,
                ),
              ),
            ),
          
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard(String sectionId, String rawName) {
    String yearLevel = 'N/A';
    String sectionName = rawName;

    // Parse the formatting like in the web admin
    if (rawName.contains('-')) {
      final parts = rawName.split('-');
      yearLevel = parts[0].trim();
      sectionName = parts.length > 1 ? parts[1].trim() : rawName;
    } else {
      final match = RegExp(r'(?:BSIT SD|BSIT BA|BSCS|BSIT)\s*(\d)').firstMatch(rawName);
      if (match != null) {
        final lvl = match.group(1);
        final suffix = (lvl == '1') ? 'st' : ((lvl == '2') ? 'nd' : ((lvl == '3') ? 'rd' : 'th'));
        yearLevel = '$lvl$suffix Year';
      }
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          if (sectionId.isNotEmpty) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => TeacherSectionStudents(
                  sectionId: sectionId,
                  sectionName: rawName,
                ),
              ),
            );
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.035),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4A843).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFD4A843).withValues(alpha: 0.28),
                    ),
                  ),
                  child: Text(
                    yearLevel.toUpperCase(),
                    style: const TextStyle(
                      color: Color(0xFFB48A33),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: TeacherThemeUtils.primary.withValues(alpha: 0.09),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.groups_rounded,
                    size: 16,
                    color: TeacherThemeUtils.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  sectionName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1F2937),
                    height: 1.15,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text(
                      'CLASS SECTION',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF9CA3AF),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        size: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
