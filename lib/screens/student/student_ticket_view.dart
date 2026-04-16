import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../utils/event_time_utils.dart';

class StudentTicketView extends StatefulWidget {
  final Map<String, dynamic> ticket;

  const StudentTicketView({super.key, required this.ticket});

  @override
  State<StudentTicketView> createState() => _StudentTicketViewState();
}

class _StudentTicketViewState extends State<StudentTicketView> {
  static const String _downloadedTicketKeyPrefix = 'downloaded_tickets_';
  bool _isDownloading = false;
  bool _isAlreadyDownloaded = false;

  @override
  void initState() {
    super.initState();
    _loadDownloadedState();
  }

  Future<void> _loadDownloadedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? 'guest';
      final storageKey = '$_downloadedTicketKeyPrefix$userId';
      final currentKey = _ticketUniqueKey(widget.ticket);

      if (currentKey.isEmpty) {
        if (mounted) setState(() => _isAlreadyDownloaded = false);
        return;
      }

      final rows = prefs.getStringList(storageKey) ?? <String>[];
      bool found = false;
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row);
          if (decoded is! Map) continue;
          final map = Map<String, dynamic>.from(decoded);
          if (_ticketUniqueKey(map) == currentKey) {
            found = true;
            break;
          }
        } catch (_) {
          // Ignore malformed rows.
        }
      }

      if (mounted) {
        setState(() => _isAlreadyDownloaded = found);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isAlreadyDownloaded = false);
      }
    }
  }

  String _ticketUniqueKey(Map<String, dynamic> ticketMap) {
    final ticketData = ticketMap['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? (ticketData[0]['id'] ?? '').toString()
        : ticketData is Map
            ? (ticketData['id'] ?? '').toString()
            : '';
    if (ticketId.isNotEmpty) return 'ticket:$ticketId';

    final event = ticketMap['events'];
    final eventId = event is Map ? (event['id'] ?? '').toString() : '';
    if (eventId.isNotEmpty) return 'event:$eventId';
    return '';
  }

  Future<void> _downloadTicket(String ticketIdDisplay) async {
    if (_isDownloading) return;
    if (_isAlreadyDownloaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ticket already saved offline.')),
      );
      return;
    }
    if (ticketIdDisplay.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ticket is not available yet.')),
      );
      return;
    }

    setState(() => _isDownloading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('user_id') ?? 'guest';
      final storageKey = '$_downloadedTicketKeyPrefix$userId';

      final currentTicket = Map<String, dynamic>.from(widget.ticket);
      currentTicket['local_cached'] = true;
      currentTicket['downloaded_at_local'] = DateTime.now().toIso8601String();
      final currentKey = _ticketUniqueKey(currentTicket);

      final existingRows = prefs.getStringList(storageKey) ?? <String>[];
      final updatedRows = <String>[];
      bool replaced = false;

      for (final row in existingRows) {
        try {
          final decoded = jsonDecode(row);
          if (decoded is! Map) {
            continue;
          }
          final decodedMap = Map<String, dynamic>.from(decoded);
          final decodedKey = _ticketUniqueKey(decodedMap);
          if (!replaced && currentKey.isNotEmpty && decodedKey == currentKey) {
            updatedRows.add(jsonEncode(currentTicket));
            replaced = true;
          } else {
            updatedRows.add(jsonEncode(decodedMap));
          }
        } catch (_) {
          // Skip malformed cached rows safely.
        }
      }

      if (!replaced) {
        updatedRows.insert(0, jsonEncode(currentTicket));
      }

      await prefs.setStringList(storageKey, updatedRows.take(150).toList());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ticket saved in app. You can open it offline in My Tickets.'),
        ),
      );
      setState(() => _isAlreadyDownloaded = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save ticket offline: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  Widget _buildDownloadActionIcon() {
    if (_isDownloading) {
      return const SizedBox(
        key: ValueKey('loading-icon'),
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD4A843)),
        ),
      );
    }

    if (_isAlreadyDownloaded) {
      return const Icon(
        Icons.download_done_rounded,
        key: ValueKey('saved-icon'),
        size: 18,
        color: Color(0xFFD4A843),
      );
    }

    return const Icon(
      Icons.download_rounded,
      key: ValueKey('default-icon'),
      size: 18,
    );
  }

  Widget _buildDownloadActionLabel() {
    if (_isAlreadyDownloaded) {
      return const Text(
        'SAVED OFFLINE',
        key: ValueKey('saved-label'),
        style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
      );
    }

    if (_isDownloading) {
      return const Text(
        'SAVING OFFLINE...',
        key: ValueKey('loading-label'),
        style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.4),
      );
    }

    return const Text(
      'DOWNLOAD TICKET',
      key: ValueKey('default-label'),
      style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.35),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ticket = widget.ticket;
    final event = ticket['events'] as Map<String, dynamic>? ?? {};
    final title = event['title'] as String? ?? 'Event';
    final startAt = event['start_at'] as String?;
    final endAt = event['end_at'] as String?;
    final location = event['location'] as String? ?? 'TBA';
    final eventType = event['event_type'] as String? ?? '';
    final graceTime = event['grace_time']?.toString() ?? '';
    final ticketData = ticket['tickets'];
    final ticketId = ticketData is List && ticketData.isNotEmpty
        ? ticketData[0]['id']?.toString() ?? ''
        : ticketData is Map ? ticketData['id']?.toString() ?? '' : '';

    // Extract attendance data
    Map<String, dynamic>? attendance;
    if (ticketData is List && ticketData.isNotEmpty) {
      final att = ticketData[0]['attendance'];
      if (att is List && att.isNotEmpty) {
        attendance = att[0];
      } else if (att is Map) {
        attendance = Map<String, dynamic>.from(att);
      }
    } else if (ticketData is Map) {
      final att = ticketData['attendance'];
      if (att is List && att.isNotEmpty) {
        attendance = att[0];
      } else if (att is Map) {
        attendance = Map<String, dynamic>.from(att);
      }
    }

    final scanStatus = attendance?['status'] as String? ?? 'unscanned';
    final checkInAt = attendance?['check_in_at'] as String?;
    final checkOutAt = attendance?['check_out_at'] as String?;
    final ticketIdDisplay = ticketId.length > 8 ? ticketId.substring(0, 8).toUpperCase() : ticketId.toUpperCase();

    final startDate = parseStoredEventDateTime(startAt);
    final endDate = parseStoredEventDateTime(endAt);
    
    String timeString = 'TBA';
    if (startDate != null) {
      final start = DateFormat('hh:mm a').format(startDate);
      if (endDate != null) {
        final end = DateFormat('hh:mm a').format(endDate);
        timeString = '$start - $end';
      } else {
        timeString = start;
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('Event Ticket', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F2937),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Center(
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 400),
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Stack(
                            children: [
                          // Shiny Background Layer (Full Height)
                          Positioned.fill(
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF7F1D1D),
                                    Color(0xFFA52A2A),
                                    Color(0xFF8B0000),
                                    Color(0xFF7F1D1D),
                                  ],
                                  stops: [0.0, 0.4, 0.6, 1.0],
                                ),
                              ),
                            ),
                          ),

                          // Diagonal Shine Overlay
                          Positioned.fill(
                            child: Opacity(
                              opacity: 0.12,
                              child: Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment(-1.0, -1.0),
                                    end: Alignment(1.0, 1.0),
                                    colors: [
                                      Colors.transparent,
                                      Colors.white,
                                      Colors.transparent,
                                    ],
                                    stops: [0.45, 0.5, 0.55],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Main Content
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Top Part (Main Ticket Info)
                              Container(
                                padding: const EdgeInsets.all(28),
                                decoration: BoxDecoration(
                                  border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Header
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.confirmation_num, color: Color(0xFFD4A843), size: 20),
                                            const SizedBox(width: 8),
                                            const Text(
                                              'PULSECONNECT',
                                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: -0.5),
                                            ),
                                          ],
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            border: Border.all(color: const Color(0xFFD4A843), width: 1.5),
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: const Text('EVENT PASS', style: TextStyle(color: Color(0xFFD4A843), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 36),
                                    
                                    // Title
                                    Text(
                                      title.toUpperCase(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 28,
                                        height: 1.1,
                                        letterSpacing: -0.5,
                                        shadows: [Shadow(color: Colors.black38, offset: Offset(0, 2), blurRadius: 4)],
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'CCS Exclusive Event'.toUpperCase(),
                                      style: TextStyle(
                                        color: const Color(0xFFD4A843).withOpacity(0.8),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                    
                                    const SizedBox(height: 36),
                                    
                                    Row(
                                      children: [
                                        Expanded(child: _buildTicketField('DATE', startDate != null ? DateFormat('MMM dd, yyyy').format(startDate) : 'TBA')),
                                        Expanded(child: _buildTicketField('TIME', timeString)),
                                      ],
                                    ),
                                    const SizedBox(height: 24),
                                    _buildTicketField('VENUE', location),
                                  ],
                                ),
                              ),

                              // Perforation Line
                              Row(
                                children: [
                                  Container(
                                    width: 14, height: 28,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF8F9FA), 
                                      borderRadius: BorderRadius.horizontal(right: Radius.circular(14)),
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          return Flex(
                                            direction: Axis.horizontal,
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: List.generate((constraints.constrainWidth() / 12).floor(), (index) {
                                              return Container(width: 6, height: 2, color: Colors.white.withValues(alpha: 0.2));
                                            }),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 14, height: 28,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF8F9FA), 
                                      borderRadius: BorderRadius.horizontal(left: Radius.circular(14)),
                                    ),
                                  ),
                                ],
                              ),

                              // Bottom Part (Stub + QR)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.fromLTRB(28, 14, 28, 28),
                                child: Column(
                                  children: [
                                    // QR Code
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.white, 
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 5))],
                                      ),
                                      child: QrImageView(
                                        data: 'PULSE-$ticketId',
                                        version: QrVersions.auto,
                                        size: 140,
                                        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF7F1D1D)),
                                        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF7F1D1D)),
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    // Ticket ID Placeholder
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        Text(
                                          'TICKET ID',
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.5),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 2.0,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          ticketIdDisplay,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontFamily: 'monospace',
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                        
                        // ── Attendance History Section ──
                        const SizedBox(height: 20),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Attendance Status',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)),
                              ),
                              const SizedBox(height: 16),

                              // Status Badge
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _getAttendanceColor(scanStatus).withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(_getAttendanceIcon(scanStatus), size: 16, color: _getAttendanceColor(scanStatus)),
                                        const SizedBox(width: 6),
                                        Text(
                                          _getAttendanceLabel(scanStatus),
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _getAttendanceColor(scanStatus)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Check-in time
                              _buildAttendanceRow(
                                'Check-in',
                                checkInAt != null
                                    ? (() {
                                        final parsed = parseStoredEventDateTime(checkInAt);
                                        return parsed != null
                                            ? DateFormat('MMM dd, yyyy — hh:mm a').format(parsed)
                                            : 'Not yet';
                                      })()
                                    : 'Not yet',
                                checkInAt != null,
                              ),
                              const SizedBox(height: 10),
                              _buildAttendanceRow(
                                'Check-out',
                                checkOutAt != null
                                    ? (() {
                                        final parsed = parseStoredEventDateTime(checkOutAt);
                                        return parsed != null
                                            ? DateFormat('MMM dd, yyyy — hh:mm a').format(parsed)
                                            : 'Not yet';
                                      })()
                                    : 'Not yet',
                                checkOutAt != null,
                              ),

                              // Event Type & Grace Time
                              if (eventType.isNotEmpty || graceTime.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                const Divider(height: 1),
                                const SizedBox(height: 12),
                                if (eventType.isNotEmpty)
                                  _buildAttendanceRow('Event Type', eventType, true),
                                if (graceTime.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  _buildAttendanceRow('Grace Time', '$graceTime min', true),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Fixed Download Button at bottom
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: (_isDownloading || _isAlreadyDownloaded)
                        ? null
                        : () => _downloadTicket(ticketIdDisplay),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildDownloadActionIcon(),
                    ),
                    label: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildDownloadActionLabel(),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7F1D1D),
                      disabledBackgroundColor: const Color(0xFF7F1D1D),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: _isAlreadyDownloaded
                          ? const Color(0xFFD4A843)
                          : Colors.white,
                      elevation: _isDownloading ? 0 : 2,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      side: BorderSide(
                        color: _isAlreadyDownloaded
                            ? const Color(0xFFD4A843).withValues(alpha: 0.55)
                            : Colors.transparent,
                        width: 1.0,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketField(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Color _getAttendanceColor(String status) {
    switch (status) {
      case 'present': return const Color(0xFF059669);
      case 'late': return const Color(0xFFD97706);
      case 'early': return const Color(0xFF2563EB);
      case 'scanned': return const Color(0xFF059669);
      case 'unscanned': return const Color(0xFF6B7280);
      default: return const Color(0xFF6B7280);
    }
  }

  IconData _getAttendanceIcon(String status) {
    switch (status) {
      case 'present': return Icons.check_circle_rounded;
      case 'late': return Icons.watch_later_rounded;
      case 'early': return Icons.bolt_rounded;
      case 'scanned': return Icons.check_circle_rounded;
      case 'unscanned': return Icons.radio_button_unchecked_rounded;
      default: return Icons.help_outline_rounded;
    }
  }

  String _getAttendanceLabel(String status) {
    switch (status) {
      case 'present': return 'Checked In';
      case 'late': return 'Checked In (Late)';
      case 'early': return 'Checked In (Early)';
      case 'scanned': return 'Checked In';
      case 'unscanned': return 'Not Yet Scanned';
      default: return status.toUpperCase();
    }
  }

  Widget _buildAttendanceRow(String label, String value, bool active) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: active ? const Color(0xFF1F2937) : Colors.grey.shade400,
          ),
        ),
      ],
    );
  }
}
