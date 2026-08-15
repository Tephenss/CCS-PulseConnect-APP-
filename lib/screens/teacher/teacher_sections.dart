import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/app_cache_service.dart';
import '../../services/mobile_backend_service.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/custom_loader.dart';
import 'teacher_section_students.dart';

class _BlockMeta {
  const _BlockMeta({
    required this.program,
    required this.yearKey,
    required this.blockCode,
    required this.displayName,
  });

  final String program;
  final String yearKey;
  final String blockCode;
  final String displayName;
}

class TeacherSections extends StatefulWidget {
  const TeacherSections({super.key});

  @override
  State<TeacherSections> createState() => _TeacherSectionsState();
}

class _TeacherSectionsState extends State<TeacherSections> {
  static const _courseOrder = ['BSIT SD', 'BSIT BA', 'BSCS', 'IRREGULAR'];
  static const _yearOrder = ['1', '2', '3', '4', 'OTHER'];
  static const _yearLabels = {
    '1': '1st Year',
    '2': '2nd Year',
    '3': '3rd Year',
    '4': '4th Year',
    'OTHER': 'Other Blocks',
  };
  static const _courseLabels = {
    'BSIT SD': 'BSIT SD',
    'BSIT BA': 'BSIT BA',
    'BSCS': 'BSCS',
    'IRREGULAR': 'IRREG',
    'OTHER': 'Other',
  };

  final _appCacheService = AppCacheService();
  final Connectivity _connectivity = Connectivity();
  final _supabase = Supabase.instance.client;
  final _searchController = TextEditingController();
  bool _isLoading = true;
  List<Map<String, dynamic>> _sections = [];
  bool _usingCachedSections = false;
  String _searchQuery = '';
  String _selectedCourse = 'BSIT SD';

  @override
  void initState() {
    super.initState();
    _fetchSections();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _extractProgram(String rawName) {
    final name = rawName.trim();
    if (name.toUpperCase() == 'IRREGULAR') return 'IRREGULAR';

    final head = RegExp(
      r'^(BSIT SD|BSIT BA|BSCS|BSIT)\b',
      caseSensitive: false,
    ).firstMatch(name);
    if (head != null) {
      final program = head.group(1)!.toUpperCase();
      return program == 'BSIT' ? 'BSIT SD' : program;
    }

    if (name.contains('-')) {
      final tail = name.split('-').length > 1
          ? name.split('-').sublist(1).join('-').trim()
          : '';
      final tailMatch = RegExp(
        r'^(BSIT SD|BSIT BA|BSCS|BSIT)\b',
        caseSensitive: false,
      ).firstMatch(tail);
      if (tailMatch != null) {
        final program = tailMatch.group(1)!.toUpperCase();
        return program == 'BSIT' ? 'BSIT SD' : program;
      }
    }
    return 'OTHER';
  }

  _BlockMeta _parseBlockMeta(String rawName) {
    final name = rawName.trim();
    var program = _extractProgram(name);
    var yearKey = 'OTHER';
    var blockCode = name;
    var displayName = name;

    final standard = RegExp(
      r'^(BSIT SD|BSIT BA|BSCS|BSIT)\s*([1-4])\s*([A-Z])$',
      caseSensitive: false,
    ).firstMatch(name);
    if (standard != null) {
      program = standard.group(1)!.toUpperCase();
      if (program == 'BSIT') program = 'BSIT SD';
      yearKey = standard.group(2)!;
      final letter = standard.group(3)!.toUpperCase();
      blockCode = '$yearKey$letter';
      displayName = '$program $blockCode';
      return _BlockMeta(
        program: program,
        yearKey: yearKey,
        blockCode: blockCode,
        displayName: displayName,
      );
    }

    if (name.contains('-')) {
      final parts = name.split('-');
      final legacyYear = parts[0].trim();
      final legacyName = parts.length > 1 ? parts.sublist(1).join('-').trim() : name;
      displayName = legacyName;
      program = _extractProgram(legacyName);
      final yearMatch = RegExp(
        r'([1-4])(?:st|nd|rd|th)?\s*year',
        caseSensitive: false,
      ).firstMatch(legacyYear);
      if (yearMatch != null) yearKey = yearMatch.group(1)!;
      final blockMatch = RegExp(
        r'\b([1-4])\s*([A-Z])$',
        caseSensitive: false,
      ).firstMatch(legacyName);
      if (blockMatch != null) {
        yearKey = blockMatch.group(1)!;
        blockCode = '$yearKey${blockMatch.group(2)!.toUpperCase()}';
      } else {
        blockCode = legacyName;
      }
      return _BlockMeta(
        program: program,
        yearKey: yearKey,
        blockCode: blockCode,
        displayName: displayName,
      );
    }

    final trailing = RegExp(
      r'\b([1-4])\s*([A-Z])$',
      caseSensitive: false,
    ).firstMatch(name);
    if (trailing != null) {
      yearKey = trailing.group(1)!;
      blockCode = '$yearKey${trailing.group(2)!.toUpperCase()}';
    }

    return _BlockMeta(
      program: program,
      yearKey: yearKey,
      blockCode: blockCode,
      displayName: displayName,
    );
  }

  List<Map<String, dynamic>> get _filteredSections {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _sections;
    return _sections.where((section) {
      final name = (section['name']?.toString() ?? '').toLowerCase();
      final meta = _parseBlockMeta(section['name']?.toString() ?? '');
      return name.contains(query) ||
          meta.blockCode.toLowerCase().contains(query) ||
          meta.displayName.toLowerCase().contains(query);
    }).toList();
  }

  List<String> get _courseTabs {
    final seen = <String>{};
    for (final section in _sections) {
      seen.add(_parseBlockMeta(section['name']?.toString() ?? '').program);
    }
    final tabs = List<String>.from(_courseOrder);
    if (seen.contains('OTHER')) tabs.add('OTHER');
    return tabs;
  }

  List<Map<String, dynamic>> _blocksForSelectedCourse() {
    return _filteredSections.where((section) {
      return _parseBlockMeta(section['name']?.toString() ?? '').program ==
          _selectedCourse;
    }).toList();
  }

  Map<String, List<Map<String, dynamic>>> _yearGroups(
    List<Map<String, dynamic>> blocks,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final section in blocks) {
      final meta = _parseBlockMeta(section['name']?.toString() ?? '');
      grouped.putIfAbsent(meta.yearKey, () => []).add(section);
    }
    for (final yearBlocks in grouped.values) {
      yearBlocks.sort((a, b) {
        final codeA = _parseBlockMeta(a['name']?.toString() ?? '').blockCode;
        final codeB = _parseBlockMeta(b['name']?.toString() ?? '').blockCode;
        return codeA.toLowerCase().compareTo(codeB.toLowerCase());
      });
    }
    return grouped;
  }

  Future<void> _fetchSections() async {
    const cacheKey = 'teacher_blocks_active';
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

      var fetched = <Map<String, dynamic>>[];
      if (MobileBackendService.isConfigured) {
        final res = await MobileBackendService().getTeacherBlocksSecure();
        if (res['ok'] == true && res['blocks'] is List) {
          fetched = List<Map<String, dynamic>>.from(
            (res['blocks'] as List).whereType<Map>().map(
              (row) => Map<String, dynamic>.from(row),
            ),
          );
        }
      }
      if (fetched.isEmpty) {
        final response = await _supabase
            .from('sections')
            .select('id, name')
            .eq('status', 'active');
        fetched = List<Map<String, dynamic>>.from(response);
      }

      fetched.sort((a, b) {
        final metaA = _parseBlockMeta(a['name']?.toString() ?? '');
        final metaB = _parseBlockMeta(b['name']?.toString() ?? '');
        final yearA = int.tryParse(metaA.yearKey) ?? 99;
        final yearB = int.tryParse(metaB.yearKey) ?? 99;
        if (yearA != yearB) return yearA.compareTo(yearB);
        return metaA.blockCode.toLowerCase().compareTo(
          metaB.blockCode.toLowerCase(),
        );
      });

      if (!mounted) return;
      setState(() {
        _sections = fetched;
        _usingCachedSections = false;
        _isLoading = false;
        final tabs = _courseTabs;
        if (!tabs.contains(_selectedCourse) && tabs.isNotEmpty) {
          _selectedCourse = tabs.first;
        }
      });
      await _appCacheService.saveJsonList(cacheKey, fetched);
    } catch (e) {
      final cached = await _appCacheService.loadJsonList(cacheKey);
      if (!mounted) return;
      setState(() {
        _sections = cached;
        _usingCachedSections = cached.isNotEmpty;
        _isLoading = false;
      });
      if (cached.isEmpty) {
        AppSnackBar.error(context, 'Failed to load blocks: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredSections;
    final isFiltering = _searchQuery.trim().isNotEmpty;
    final courseBlocks = _blocksForSelectedCourse();
    final yearGroups = _yearGroups(courseBlocks);

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: RefreshIndicator(
        onRefresh: _fetchSections,
        color: TeacherThemeUtils.primary,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
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
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Blocks',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
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
                                isFiltering
                                    ? '${filtered.length} of ${_sections.length} Blocks'
                                    : '${_sections.length} Active Blocks',
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
                        const SizedBox(height: 16),
                        TextField(
                          controller: _searchController,
                          onChanged: (value) =>
                              setState(() => _searchQuery = value),
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Search block',
                            hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 13,
                            ),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.15),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 0,
                              horizontal: 16,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_isLoading)
              const SliverFillRemaining(
                child: Center(child: PulseConnectLoader()),
              )
            else if (_sections.isEmpty)
              SliverFillRemaining(child: _buildEmptyState(global: true))
            else ...[
              SliverToBoxAdapter(child: _buildCourseTabs()),
              if (courseBlocks.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(global: false),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final yearKey = _yearOrder
                          .where((key) => yearGroups.containsKey(key))
                          .toList()[index];
                      final yearBlocks = yearGroups[yearKey]!;
                      return _buildYearRow(yearKey, yearBlocks);
                    }, childCount: _yearOrder
                        .where((key) => yearGroups.containsKey(key))
                        .length),
                  ),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseTabs() {
    final tabs = _courseTabs;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: tabs.map((course) {
            final isActive = course == _selectedCourse;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => setState(() => _selectedCourse = course),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isActive
                        ? TeacherThemeUtils.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12),
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: isActive
                            ? TeacherThemeUtils.primary
                            : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                  child: Text(
                    _courseLabels[course] ?? course,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                      color: isActive
                          ? TeacherThemeUtils.mid
                          : const Color(0xFF6B7280),
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildYearRow(String yearKey, List<Map<String, dynamic>> blocks) {
    final label = _yearLabels[yearKey] ?? _yearLabels['OTHER']!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Row(
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Divider(height: 1, color: Color(0xFFE5E7EB)),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: TeacherThemeUtils.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${blocks.length} block${blocks.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: TeacherThemeUtils.mid,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              physics: const BouncingScrollPhysics(),
              itemCount: blocks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final section = blocks[index];
                final rawName = section['name']?.toString() ?? 'Unknown';
                final meta = _parseBlockMeta(rawName);
                final count =
                    int.tryParse(section['student_count']?.toString() ?? '') ??
                    0;
                return SizedBox(
                  width: 158,
                  child: _buildSectionCard(
                    section['id']?.toString() ?? '',
                    rawName,
                    meta.blockCode,
                    meta.program,
                    count,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({required bool global}) {
    final isSearch = _searchQuery.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
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
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(
                Icons.groups_rounded,
                size: 40,
                color: Colors.grey.shade300,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              global
                  ? (_usingCachedSections
                        ? 'No cached blocks found'
                        : 'No blocks exist')
                  : (isSearch
                        ? 'No matching blocks'
                        : 'No blocks in this program'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              global
                  ? (_usingCachedSections
                        ? 'Reconnect once to refresh the latest blocks.'
                        : 'Blocks added by the Admin will appear here.')
                  : (isSearch
                        ? 'Try another search or switch program.'
                        : 'Blocks for this program will appear here.'),
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _watermarkAsset(String program) {
    if (program.startsWith('BSIT')) return 'assets/BSIT.png';
    if (program == 'BSCS') return 'assets/CS.png';
    return 'assets/CCS.png';
  }

  Widget _buildSectionCard(
    String sectionId,
    String rawName,
    String blockCode,
    String program,
    int studentCount,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          if (sectionId.isEmpty) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => TeacherSectionStudents(
                sectionId: sectionId,
                sectionName: rawName,
              ),
            ),
          );
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
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              children: [
                Positioned(
                  right: -16,
                  bottom: -18,
                  child: Opacity(
                    opacity: 0.12,
                    child: Image.asset(
                      _watermarkAsset(program),
                      width: 108,
                      height: 108,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: TeacherThemeUtils.primary.withValues(
                            alpha: 0.09,
                          ),
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
                        blockCode,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1F2937),
                          height: 1.1,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        studentCount == 1
                            ? '1 registered student'
                            : '$studentCount registered students',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text(
                            'CLASS BLOCK',
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
