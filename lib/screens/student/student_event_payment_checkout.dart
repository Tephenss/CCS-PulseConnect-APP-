import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import '../../services/mobile_backend_service.dart';

class StudentEventPaymentCheckout extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  final double eventFee;
  const StudentEventPaymentCheckout({
    super.key,
    required this.eventId,
    required this.eventTitle,
    required this.eventFee,
  });
  @override
  State<StudentEventPaymentCheckout> createState() =>
      _StudentEventPaymentCheckoutState();
}

class _StudentEventPaymentCheckoutState
    extends State<StudentEventPaymentCheckout>
    with WidgetsBindingObserver {
  static const _navy = Color(0xFF142A3A);
  static const _blue = Color(0xFF0878B7);
  Timer? _pollTimer;
  Timer? _countdownTimer;
  String _status = 'loading';
  String _error = '';
  String? _qrImage;
  ImageProvider? _qrProvider;
  Uint8List? _qrBytesCache;
  DateTime? _expiresAt;
  double _amount = 0;
  bool _checking = false;
  bool _savingQr = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_beginCheckout());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        const {'pending', 'creating', 'processing'}.contains(_status)) {
      unawaited(_refreshStatus());
    }
  }

  Future<void> _beginCheckout() async {
    if (!mounted) return;
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    setState(() {
      _status = 'loading';
      _error = '';
      _qrImage = null;
      _qrProvider = null;
      _qrBytesCache = null;
    });
    final result = await MobileBackendService.createEventPaymentCheckout(
      widget.eventId,
    );
    if (!mounted) return;
    if (result['ok'] != true) {
      setState(() {
        _status = 'error';
        _error = result['error']?.toString() ?? 'Could not start payment.';
      });
      return;
    }
    if (result['already_registered'] == true) {
      setState(() => _status = 'paid');
      return;
    }
    final rawExpiry = result['expires_at']?.toString();
    final qrImage = result['qr_image_url']?.toString();
    final qrProvider = _prepareQrProvider(qrImage);
    setState(() {
      _status = result['status']?.toString() ?? 'pending';
      _amount =
          double.tryParse(result['amount']?.toString() ?? '') ??
          widget.eventFee;
      _qrImage = qrImage;
      _qrProvider = qrProvider;
      _expiresAt = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    });
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_refreshStatus()),
    );
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status == 'pending' && _expiresAt != null) {
        setState(() {});
      }
    });
  }

  Future<void> _refreshStatus() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      final result = await MobileBackendService.fetchEventPaymentCheckoutStatus(
        widget.eventId,
      );
      if (!mounted || result['ok'] != true) return;
      final status = result['status']?.toString() ?? 'not_started';
      if (status == 'paid' && result['registered'] == true) {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        setState(() {
          _status = 'paid';
          _qrImage = null;
          _qrProvider = null;
          _qrBytesCache = null;
          _error = '';
        });
        return;
      }
      if (status == 'registration_failed' ||
          status == 'failed' ||
          status == 'expired') {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        setState(() {
          _status = status;
          _error = result['failure_reason']?.toString() ?? '';
          _qrImage = null;
          _qrProvider = null;
          _qrBytesCache = null;
        });
        return;
      }
      final nextStatus = status == 'paid' ? 'processing' : status;
      final nextAmount =
          double.tryParse(result['amount']?.toString() ?? '') ?? _amount;
      final nextQr = result['qr_image_url']?.toString();
      final nextExpiry = DateTime.tryParse(
        result['expires_at']?.toString() ?? '',
      );
      final qrChanged =
          nextQr != null && nextQr.isNotEmpty && nextQr != _qrImage;
      final amountChanged = nextAmount != _amount;
      final expiryChanged = nextExpiry != null && nextExpiry != _expiresAt;
      if (nextStatus == _status &&
          !qrChanged &&
          !amountChanged &&
          !expiryChanged) {
        return;
      }
      final nextQrProvider = qrChanged ? _prepareQrProvider(nextQr) : null;
      setState(() {
        _status = nextStatus;
        _amount = nextAmount;
        if (qrChanged) {
          _qrImage = nextQr;
          _qrProvider = nextQrProvider;
        }
        if (expiryChanged) _expiresAt = nextExpiry;
      });
    } finally {
      _checking = false;
    }
  }

  ImageProvider? _prepareQrProvider(String? image) {
    _qrBytesCache = null;
    final raw = (image ?? '').trim();
    if (raw.isEmpty) return null;
    if (raw.startsWith('http')) return NetworkImage(raw);
    final comma = raw.indexOf(',');
    final encoded = raw.startsWith('data:') && comma >= 0
        ? raw.substring(comma + 1)
        : raw;
    try {
      _qrBytesCache = base64Decode(encoded);
      return MemoryImage(_qrBytesCache!);
    } on FormatException {
      return null;
    }
  }

  String _expiryText() {
    final expiry = _expiresAt;
    if (expiry == null) return 'Valid for 30 minutes';
    final remaining = expiry.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0)
      return 'QR may have expired. Generate a new QR to pay.';
    final minutes = remaining.inMinutes.toString().padLeft(2, '0');
    final seconds = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return 'QR expires in $minutes:$seconds';
  }

  Future<void> _saveQr() async {
    final bytes = _qrBytesCache;
    if (bytes == null || _savingQr) return;
    setState(() => _savingQr = true);
    try {
      var allowed = await Gal.hasAccess(toAlbum: true);
      if (!allowed) allowed = await Gal.requestAccess(toAlbum: true);
      if (!allowed) throw Exception('Allow photo access to save the QR code.');
      await Gal.putImageBytes(
        bytes,
        name: 'PulseConnect_Payment_' + widget.eventId,
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment QR saved to your photos.')),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', '')),
          ),
        );
    } finally {
      if (mounted) setState(() => _savingQr = false);
    }
  }

  Widget _statusCard(IconData icon, String title, String body, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 42, color: color),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _navy,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF64748B), height: 1.45),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final amount = _amount > 0 ? _amount : widget.eventFee;
    final hasQr = _status == 'pending' && _qrProvider != null;
    final working = const {
      'loading',
      'creating',
      'processing',
    }.contains(_status);
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FA),
      appBar: AppBar(
        title: const Text('Event Payment'),
        backgroundColor: Colors.white,
        foregroundColor: _navy,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          children: [
            Text(
              widget.eventTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _navy,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x120F172A),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                children: [
                  const Text(
                    'AMOUNT TO PAY',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '₱' + amount.toStringAsFixed(2),
                    style: const TextStyle(
                      color: _navy,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'GCash or another participating QR Ph app',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (hasQr)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: [
                    SizedBox(
                      width: 264,
                      height: 264,
                      child: Image(
                        image: _qrProvider!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Text('Could not load QR. Retry checkout.'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _expiryText(),
                      style: const TextStyle(
                        color: _blue,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Open GCash, choose Scan QR, and scan this code. The amount is encoded in the QR; verify it in GCash before confirming.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF475569), height: 1.45),
                    ),
                    TextButton.icon(
                      onPressed: _savingQr ? null : _saveQr,
                      icon: _savingQr
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                      label: const Text('Save QR to this phone'),
                    ),
                    const Text(
                      'If paying on this same phone, save the QR and use GCash scan-from-gallery if available, or display it on another device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              )
            else if (working)
              _statusCard(
                Icons.lock_clock_outlined,
                _status == 'processing'
                    ? 'Confirming your payment'
                    : 'Preparing secure QR',
                _status == 'processing'
                    ? 'Payment is being checked securely. Please keep this page open.'
                    : 'We are creating your one-time QR code. This may take a few seconds.',
                _blue,
              )
            else if (_status == 'paid')
              _statusCard(
                Icons.check_circle_outline,
                'Payment successful',
                'Your payment is confirmed and your event registration is ready.',
                const Color(0xFF15966A),
              )
            else if (_status == 'registration_failed')
              _statusCard(
                Icons.support_agent,
                'Payment received',
                'Payment was confirmed, but registration could not be completed automatically. Contact the event organizer. ' +
                    (_error.isEmpty ? '' : _error),
                const Color(0xFFB45309),
              )
            else
              _statusCard(
                Icons.qr_code_2,
                _status == 'expired' ? 'QR expired' : 'Payment not completed',
                _error.isNotEmpty
                    ? _error
                    : 'Create a new secure QR code to try again.',
                const Color(0xFFB45309),
              ),
            if (_status == 'pending') ...[
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _blue,
                    ),
                  ),
                  SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      'Waiting for PayMongo payment confirmation…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            if (_status == 'paid')
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Back to event',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              )
            else if (_status == 'failed' ||
                _status == 'expired' ||
                _status == 'error')
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _beginCheckout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Generate new QR',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            if (working) ...[
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  'Do not close the app while we confirm the payment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
