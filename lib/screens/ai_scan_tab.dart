// lib/screens/ai_scan_tab.dart
// ✅ Step chips 1-5 are fully interactive
// ✅ Duplicate image detection
// ✅ Google Sheets link shown after save
// ✅ Save success dialog
// ✅ NEW: "Review & Edit AI Findings" hint banner at top of review sheet
// ✅ Inline edit per hazard preserved

import 'dart:io' show File;
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../main.dart';
import '../services/gemini_vision.dart';
import '../services/local_ai.dart';
import '../services/local_db.dart';
import '../services/image_storage.dart';
import '../services/sync_service.dart';
import '../services/pdf_export.dart';
import '../services/geo_service.dart';
import '../widgets/hazard_annotated_image.dart';
import '../widgets/universal_app_bar.dart';
import '../widgets/voice_text_field.dart';
import '../services/i18n.dart';
import '../services/ai_audit_service.dart';
import '../services/ai_correction_service.dart';

class AIScanTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;
  final bool showAppBar;
  const AIScanTab({
    super.key,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
    this.showAppBar = true,
  });
  @override
  State<AIScanTab> createState() => _AIScanTabState();
}

class _AIScanTabState extends State<AIScanTab> {
  XFile?     _pickedFile;
  Uint8List? _imageBytes;
  bool       _analyzing = false;
  Map<String, dynamic>? _result;
  // Pristine snapshot of the AI output the moment analysis finished, so we can
  // diff it against the user's edits on save and feed real mistakes back into
  // training. Deep-copied so later edits to _result don't mutate it.
  Map<String, dynamic>? _originalAiResult;
  String     _step = '';
  String?    _savedImageHash;
  int _currentStep = 0;
  String? _savedIncidentId;
  bool    _isSaved = false;
  final Map<int, TextEditingController> _mitigationControllers = {};
  final Map<int, bool> _hazardClosed = {};
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _locationController = TextEditingController();
  final List<GlobalKey>  _hazardRowKeys    = [];
  int? _highlightedRow;

  // GPS geo-tagging
  LocationData? _capturedLocation;
  bool _capturingLocation = false;

  static const String _sheetUrl =
      'https://docs.google.com/spreadsheets/d/16BeCJ3KpXiYzl-cbcfRUFL1vZkPtzyXzUHZP5usNZhY/edit';

  @override
  void dispose() {
    _scrollController.dispose();
    _locationController.dispose();
    for (final c in _mitigationControllers.values) { c.dispose(); }
    super.dispose();
  }

  String _computeHash(Uint8List bytes) {
    int h = 0;
    final step = bytes.length > 1000 ? bytes.length ~/ 500 : 1;
    for (int i = 0; i < bytes.length; i += step) {
      h ^= (bytes[i] << (i % 24));
      h  =  h & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  void _buildHazardKeys(int count) {
    _hazardRowKeys.clear();
    _mitigationControllers.forEach((_, c) => c.dispose());
    _mitigationControllers.clear();
    _hazardClosed.clear();
    for (int i = 0; i < count; i++) {
      _hazardRowKeys.add(GlobalKey());
      _mitigationControllers[i] = TextEditingController();
      _hazardClosed[i] = false;
    }
  }

  void _onBboxTap(int index) {
    setState(() => _highlightedRow =
        index == _highlightedRow ? null : index);
    if (index >= _hazardRowKeys.length) return;
    final ctx = _hazardRowKeys[index].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut, alignment: 0.1);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    // ✅ Step 1: Open camera/gallery IMMEDIATELY — no GPS blocking.
    // For GALLERY, pick at FULL quality (no resize) so the image's EXIF —
    // including embedded GPS — is preserved; image_picker's imageQuality/
    // maxWidth/maxHeight re-encode the file and strip all metadata.
    // We downscale in-app afterwards for fast analysis. Camera photos have
    // no useful EXIF GPS here (we watermark with live device GPS instead),
    // so we let the picker resize those directly.
    final picker = ImagePicker();
    final bool isGallery = source == ImageSource.gallery;
    final picked = isGallery
        ? await picker.pickImage(source: source)
        : await picker.pickImage(
            source: source, imageQuality: 80,
            maxWidth: 1024, maxHeight: 1024);
    if (picked == null) return;

    // Step 2: Read image bytes. Keep the ORIGINAL (with EXIF) for gallery so
    // GPS can be extracted; use a downscaled+compressed copy for fast analysis.
    // Both camera and gallery images are compressed for a quicker upload.
    final Uint8List originalBytes = await picked.readAsBytes();
    Uint8List bytes = _downscaleForAnalysis(originalBytes);

    // Step 3: Update state immediately — start AI analysis
    setState(() {
      _pickedFile     = picked;
      _imageBytes     = bytes;
      _capturedLocation = null;
      _analyzing      = true;
      _result         = null;
      _isSaved        = false;
      _savedIncidentId = null;
      _hazardRowKeys.clear();
      _highlightedRow = null;
      _currentStep    = 2;
    });

    // Step 4: Capture GPS silently in background (non-blocking).
    // ★ Try EXIF GPS from the ORIGINAL (metadata-preserving) bytes for
    //   gallery uploads; watermark the downscaled display image.
    _captureLocationSmart(originalBytes, bytes, source);

    await _analyze();
  }

  /// Captures GPS location silently in background without showing any UI.
  /// [exifBytes] retains EXIF (used for GPS extraction); [displayBytes] is the
  /// downscaled image shown/analyzed and watermarked.
  /// ★ Try EXIF GPS for gallery, device GPS for camera.
  Future<void> _captureLocationSmart(
      Uint8List exifBytes, Uint8List displayBytes, ImageSource source) async {
    if (source == ImageSource.gallery) {
      try {
        final exifLocation = await GeoService.getLocationFromExif(exifBytes).timeout(
          const Duration(seconds: 5), onTimeout: () => null);
        if (!mounted) return;
        if (exifLocation != null && exifLocation.isValid) {
          setState(() {
            _capturedLocation = exifLocation;
            _locationController.text = GeoService.getDisplayAddress(exifLocation);
          });
          // Watermark the DISPLAY image with the EXIF-derived location.
          final watermarked = await GeoService.addWatermarkToImage(displayBytes, exifLocation);
          if (watermarked != null && mounted) {
            setState(() => _imageBytes = watermarked);
          }
          return; // EXIF worked
        }
      } catch (_) {}
    }
    // Fallback to device GPS — watermark the display image.
    _captureGpsInBackground(displayBytes);
  }

  Future<void> _captureGpsInBackground(Uint8List originalBytes) async {
    LocationData? location;
    try {
      location = await GeoService.getCurrentLocation().timeout(
        const Duration(seconds: 10),
        onTimeout: () => LocationData(error: 'GPS timeout'),
      );
    } catch (e) {
      location = LocationData(error: 'GPS unavailable');
    }

    if (!mounted) return;

    // Update state silently with location data
    setState(() {
      _capturedLocation = location;
      if (location?.isValid == true) {
        _locationController.text = GeoService.getDisplayAddress(location!);
      }
    });

    // Add watermark silently if GPS was captured successfully
    if (location != null && location.isValid) {
      final watermarked = await GeoService.addWatermarkToImage(originalBytes, location);
      if (watermarked != null && mounted) {
        setState(() {
          _imageBytes = watermarked;
        });
      }
    }
  }

  /// Downscale a full-resolution gallery image (kept full so EXIF survives the
  /// pick) to ~1024px on the long edge for fast upload/analysis. Falls back to
  /// the original bytes if decoding fails.
  /// Downscale for FASTER analysis: a smaller JPEG uploads quicker and the
  /// vision model processes it faster, with negligible impact on hazard
  /// detection at 900px. Re-encode even already-small images to compress them.
  Uint8List _downscaleForAnalysis(Uint8List original, {int maxEdge = 900}) {
    try {
      final decoded = img.decodeImage(original);
      if (decoded == null) return original;
      final img.Image resized =
          (decoded.width <= maxEdge && decoded.height <= maxEdge)
              ? decoded
              : (decoded.width >= decoded.height
                  ? img.copyResize(decoded, width: maxEdge)
                  : img.copyResize(decoded, height: maxEdge));
      final out = Uint8List.fromList(img.encodeJpg(resized, quality: 72));
      // Only use the re-encoded copy if it's actually smaller.
      return out.length < original.length ? out : original;
    } catch (_) {
      return original;
    }
  }

  Future<void> _analyze() async {
    setState(() => _step = 'Analyzing hazards…');
    try {
      Map<String, dynamic>? result;
      bool failedDueToInternet = false;

      try {
        result = kIsWeb
            ? await GeminiVision.analyseImageBytes(_imageBytes!)
            : await GeminiVision.analyseImage(File(_pickedFile!.path));
      } catch (e) {
        // ✅ FIX: Check if it's a network/connectivity error
        final errorStr = e.toString().toLowerCase();
        if (errorStr.contains('socket') ||
            errorStr.contains('network') ||
            errorStr.contains('connection') ||
            errorStr.contains('timeout') ||
            errorStr.contains('failed host lookup')) {
          failedDueToInternet = true;
        }

        // Show error and stop - don't fall back to demo
        if (mounted) {
          setState(() { _analyzing = false; _currentStep = 1; });
          if (failedDueToInternet) {
            _snack('⚠️ Poor internet connectivity. Please try again later.', AppColors.red);
          } else {
            _snack('⚠️ Analysis failed: ${e.toString()}', AppColors.red);
          }
        }
        return; // Stop here, don't continue
      }

      if (mounted) {
        final hazards = (result?['hazards'] as List?) ?? [];
        _buildHazardKeys(hazards.length);
        setState(() {
          _result      = result;
          // Deep copy via JSON round-trip so edits to _result never mutate the
          // pristine snapshot we diff against on save.
          _originalAiResult = result == null
              ? null
              : jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
          _analyzing   = false;
          _currentStep = 3;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _analyzing = false; _currentStep = 1; });
        _snack('Analysis failed: $e', AppColors.red);
      }
    }
  }

  // ─── STEP 3: REVIEW (with inline edit per hazard) ───────────
  void _openReviewSheet() {
    if (_result == null) return;
    setState(() => _currentStep = 3);

    final sl        = SL.of(context);
    final riskColor = _sevColor(
        _result!['overallRisk']?.toString() ?? 'MEDIUM');

    final List<Map<String, dynamic>> editableHazards =
        ((_result!['hazards'] as List?) ?? [])
            .map((h) => Map<String, dynamic>.from(h as Map))
            .toList();

    final Map<int, Map<String, TextEditingController>> editControllers = {};
    final Map<int, bool> editingIndex = {};

    final summaryCtrl = TextEditingController(
        text: _result!['summary']?.toString() ?? '');
    bool editingSummary = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Map<String, TextEditingController> ctrlsFor(int i) {
            if (!editControllers.containsKey(i)) {
              final h = editableHazards[i];
              editControllers[i] = {
                'name':             TextEditingController(text: h['name']?.toString() ?? ''),
                'description':      TextEditingController(text: h['description']?.toString() ?? ''),
                'regulation':       TextEditingController(text: h['regulation']?.toString() ?? ''),
                'correctiveAction': TextEditingController(text: h['correctiveAction']?.toString() ?? ''),
                'wsaCause':         TextEditingController(text: h['wsaCause']?.toString() ?? ''),
                'type':             TextEditingController(text: h['type']?.toString() ?? ''),
              };
            }
            return editControllers[i]!;
          }

          void applyEdits(int i) {
            final ctrls = ctrlsFor(i);
            editableHazards[i]['name']             = ctrls['name']!.text.trim();
            editableHazards[i]['description']      = ctrls['description']!.text.trim();
            editableHazards[i]['regulation']       = ctrls['regulation']!.text.trim();
            editableHazards[i]['correctiveAction'] = ctrls['correctiveAction']!.text.trim();
            editableHazards[i]['wsaCause']         = ctrls['wsaCause']!.text.trim();
            editableHazards[i]['type']             = ctrls['type']!.text.trim();
          }

          final fieldBg = sl.isDark
              ? const Color(0xFF1C1F2E)
              : const Color(0xFFF0F1F5);

          // ✅ NEW: Prominent hint banner — first thing user sees in review
          final hintBanner = Container(
            margin: const EdgeInsets.fromLTRB(0, 0, 0, 12),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.accent.withOpacity(0.12),
                  AppColors.cyan.withOpacity(0.08),
                ]),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppColors.accent.withOpacity(0.4), width: 1)),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.edit_note_rounded,
                    color: AppColors.accent, size: 20)),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Review & Edit AI Findings',
                      style: TextStyle(color: sl.text1, fontSize: 12.5,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                      'Tap ✏️ Edit on any hazard to modify name, '
                      'severity, description, regulation, or '
                      'corrective action. Then tap Save with edits.',
                      style: TextStyle(color: sl.text3, fontSize: 10,
                          height: 1.35)),
                ])),
            ]));

          Widget editField(TextEditingController c,
              {String hint = '', int lines = 1}) =>
            TextField(
              controller: c,
              maxLines: lines,
              style: TextStyle(color: sl.text1,
                  fontSize: 11, height: 1.4),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: sl.text4, fontSize: 10),
                filled: true, fillColor: fieldBg,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(
                      color: sl.border.withOpacity(0.5))),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: const BorderSide(
                      color: AppColors.accent, width: 2))));

          Widget editableRow(String label, TextEditingController c,
              {int lines = 1}) =>
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                SizedBox(width: 84, child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(label, style: TextStyle(
                      color: sl.text4, fontSize: 9,
                      fontWeight: FontWeight.w600)))),
                Expanded(child: editField(c,
                    hint: label, lines: lines)),
              ]));

          return DraggableScrollableSheet(
            initialChildSize: 0.88,
            maxChildSize: 0.97,
            minChildSize: 0.5,
            builder: (_, ctrl) => Container(
              decoration: BoxDecoration(
                color: sl.isDark
                    ? const Color(0xFF1C1F2E) : Colors.white,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20))),
              child: Column(children: [
                Center(child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: sl.border,
                    borderRadius: BorderRadius.circular(99)))),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: riskColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: riskColor)),
                      child: Text(
                        '${_result!['overallRisk']} · ${_result!['riskScore']}/100',
                        style: TextStyle(color: riskColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w800))),
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      '${editableHazards.length} Hazards Identified',
                      style: TextStyle(color: sl.text1,
                          fontSize: 14,
                          fontWeight: FontWeight.w700))),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                            color: AppColors.accent.withOpacity(0.3))),
                      child: const Text('✏️ Tap Edit',
                        style: TextStyle(
                            color: AppColors.accent,
                            fontSize: 9,
                            fontWeight: FontWeight.w700))),
                    const SizedBox(width: 8),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(Icons.close, color: sl.text4, size: 20),
                      onPressed: () {
                        for (final m in editControllers.values) {
                          for (final c in m.values) { c.dispose(); }
                        }
                        summaryCtrl.dispose();
                        Navigator.pop(ctx);
                      }),
                  ])),
                Divider(height: 1, color: sl.border),

                Expanded(child: ListView(
                  controller: ctrl,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
                  children: [
                    // ✅ NEW: hint banner is the first item
                    hintBanner,

                    // ── GPS Location Card ──────────────────
                    if (_capturedLocation != null && _capturedLocation!.isValid)
                      _locationCard(sl),

                    // ── Editable summary ──────────────────
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: sl.isDark
                            ? const Color(0xFF252840)
                            : const Color(0xFFF5F6FA),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: sl.border.withOpacity(0.5))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                        Row(children: [
                          Text('SUMMARY', style: TextStyle(
                              color: sl.text4, fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6)),
                          const Spacer(),
                          GestureDetector(
                            onTap: () => setLocal(() =>
                                editingSummary = !editingSummary),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: editingSummary
                                    ? AppColors.accent
                                    : AppColors.accent.withOpacity(0.1),
                                borderRadius:
                                    BorderRadius.circular(6)),
                              child: Text(
                                editingSummary ? 'Done' : 'Edit',
                                style: TextStyle(
                                  color: editingSummary
                                      ? Colors.white
                                      : AppColors.accent,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700)))),
                        ]),
                        const SizedBox(height: 6),
                        editingSummary
                          ? editField(summaryCtrl,
                              hint: 'Overall summary…', lines: 3)
                          : Text(summaryCtrl.text.isNotEmpty
                                ? summaryCtrl.text
                                : _result!['summary']?.toString() ?? '',
                              style: TextStyle(
                                  color: sl.text2,
                                  fontSize: 11, height: 1.5)),
                      ])),
                    const SizedBox(height: 10),

                    // ── Hazard cards ──────────────────────
                    ...editableHazards.asMap().entries.map((e) {
                      final i  = e.key;
                      final h  = e.value;
                      final sc = _sevColor(
                          h['severity']?.toString() ?? 'MEDIUM');
                      final isEditing = editingIndex[i] ?? false;
                      final ctrls = isEditing ? ctrlsFor(i) : null;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: sl.isDark
                                ? const Color(0xFF252840)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isEditing
                                  ? AppColors.accent.withOpacity(0.5)
                                  : sc.withOpacity(0.35),
                              width: isEditing ? 1.5 : 1)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                            Row(children: [
                              Container(
                                width: 22, height: 22,
                                decoration: BoxDecoration(
                                    color: sc, shape: BoxShape.circle),
                                child: Center(child: Text('${i+1}',
                                  style: const TextStyle(
                                    color: Colors.white, fontSize: 9,
                                    fontWeight: FontWeight.w800)))),
                              const SizedBox(width: 8),
                              Expanded(child: isEditing
                                ? editField(ctrls!['name']!,
                                    hint: 'Hazard name')
                                : Text(h['name']?.toString() ?? '—',
                                    style: TextStyle(
                                        color: sl.text1, fontSize: 13,
                                        fontWeight: FontWeight.w700))),
                              const SizedBox(width: 8),
                              isEditing
                                ? _severityDropdown(
                                    h['severity']?.toString() ?? 'MEDIUM',
                                    sl,
                                    (val) => setLocal(() =>
                                        editableHazards[i]['severity'] = val))
                                : Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: sc.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: sc)),
                                    child: Text(
                                      h['severity']?.toString() ?? '—',
                                      style: TextStyle(
                                          color: sc, fontSize: 8,
                                          fontWeight: FontWeight.w800))),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => setLocal(() {
                                  if (isEditing) {
                                    applyEdits(i);
                                    editingIndex[i] = false;
                                  } else {
                                    ctrlsFor(i);
                                    editingIndex[i] = true;
                                  }
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isEditing
                                        ? AppColors.green
                                        : AppColors.accent.withOpacity(0.1),
                                    borderRadius:
                                        BorderRadius.circular(7)),
                                  child: Text(
                                    isEditing ? '✓ Done' : '✏️ Edit',
                                    style: TextStyle(
                                      color: isEditing
                                          ? Colors.white
                                          : AppColors.accent,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)))),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => setLocal(() {
                                  editableHazards.removeAt(i);
                                  editControllers.remove(i);
                                  editingIndex.remove(i);
                                  _result!['hazards'] = editableHazards;
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.red.withOpacity(0.1),
                                    borderRadius:
                                        BorderRadius.circular(7)),
                                  child: const Text(
                                    '🗑 Delete',
                                    style: TextStyle(
                                      color: AppColors.red,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)))),
                            ]),
                            const SizedBox(height: 8),

                            if (!isEditing) ...[
                              Text(
                                h['description']?.toString() ?? '',
                                style: TextStyle(
                                    color: sl.text2,
                                    fontSize: 11, height: 1.4)),
                              const SizedBox(height: 5),
                              _reviewRow('⚖️ Regulation',
                                  h['regulation']?.toString() ?? '', sl),
                              _reviewRow('🔧 Action',
                                  h['correctiveAction']?.toString() ?? '', sl),
                              if ((h['wsaCause']?.toString() ?? '').isNotEmpty)
                                _reviewRow('📋 WSA Cause',
                                    h['wsaCause']?.toString() ?? '', sl),
                              if ((h['type']?.toString() ?? '').isNotEmpty)
                                _reviewRow('🔍 Type',
                                    h['type']?.toString() ?? '', sl),
                            ] else ...[
                              editableRow('Description',
                                  ctrls!['description']!, lines: 3),
                              editableRow('⚖️ Regulation',
                                  ctrls['regulation']!, lines: 2),
                              editableRow('🔧 Action',
                                  ctrls['correctiveAction']!, lines: 2),
                              editableRow('📋 WSA Cause',
                                  ctrls['wsaCause']!),
                              editableRow('🔍 Type', ctrls['type']!),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () => setLocal(() {
                                  editControllers.remove(i);
                                  editingIndex[i] = false;
                                }),
                                child: Row(children: [
                                  Icon(Icons.undo_rounded,
                                      size: 12, color: sl.text4),
                                  const SizedBox(width: 4),
                                  Text('Discard changes',
                                    style: TextStyle(
                                        color: sl.text4, fontSize: 10)),
                                ])),
                            ],
                          ])));
                    }).toList(),
                  ])),

                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
                  decoration: BoxDecoration(
                    color: sl.isDark
                        ? const Color(0xFF252840) : Colors.white,
                    border: Border(top: BorderSide(
                        color: sl.border.withOpacity(0.4)))),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    if (editingIndex.values.any((v) => v))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.amber.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppColors.amber.withOpacity(0.35))),
                          child: const Row(children: [
                            Icon(Icons.edit_note_rounded,
                                color: AppColors.amber, size: 14),
                            SizedBox(width: 6),
                            Expanded(child: Text(
                              'Tap ✓ Done on each hazard to apply edits before saving.',
                              style: TextStyle(
                                  color: AppColors.amber,
                                  fontSize: 10, height: 1.4))),
                          ]))),
                    Row(children: [
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            for (final i in editingIndex.keys) {
                              if (editingIndex[i] == true) {
                                applyEdits(i);
                              }
                            }
                            if (editingSummary) {
                              _result!['summary'] = summaryCtrl.text.trim();
                            }
                            _result!['hazards'] = editableHazards;
                            for (final m in editControllers.values) {
                              for (final c in m.values) { c.dispose(); }
                            }
                            summaryCtrl.dispose();
                            Navigator.pop(ctx);
                            setState(() => _currentStep = 4);
                            _save();
                          },
                          icon: const Icon(Icons.save_outlined,
                              size: 14, color: Colors.white),
                          label: const Text(
                            'Save with edits',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.green,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10))),
                        )),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            for (final m in editControllers.values) {
                              for (final c in m.values) { c.dispose(); }
                            }
                            summaryCtrl.dispose();
                            Navigator.pop(ctx);
                            setState(() => _currentStep = 4);
                            _save();
                          },
                          icon: const Icon(Icons.check_circle_outline,
                              size: 13, color: AppColors.accent),
                          label: const Text('Save as-is',
                            style: TextStyle(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w700,
                                fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: AppColors.accent, width: 1.5),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10))),
                        )),
                    ]),
                  ])),
              ])));
        }));
  }

  Widget _severityDropdown(
      String current, SL sl, ValueChanged<String> onChanged) {
    const sevs = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: _sevColor(current).withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _sevColor(current))),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: sevs.contains(current) ? current : 'MEDIUM',
          isDense: true,
          dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
          style: TextStyle(
              color: _sevColor(current), fontSize: 9,
              fontWeight: FontWeight.w800),
          icon: Icon(Icons.arrow_drop_down,
              color: _sevColor(current), size: 14),
          items: sevs.map((s) => DropdownMenuItem(
              value: s,
              child: Text(s, style: TextStyle(
                  color: _sevColor(s), fontSize: 9,
                  fontWeight: FontWeight.w800)))).toList(),
          onChanged: (v) { if (v != null) onChanged(v); })));
  }

  Widget _reviewRow(String label, String value, SL sl) =>
    Padding(padding: const EdgeInsets.only(top: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90, child: Text(label, style: TextStyle(
            color: sl.text4, fontSize: 9, fontWeight: FontWeight.w600))),
        Expanded(child: Text(value, style: TextStyle(
            color: sl.text1, fontSize: 10, height: 1.4))),
      ]));

  // ─── STEP 4: SAVE ────────────────────────────────────────────
  Future<void> _save() async {
    if (_result == null) return;

    if (_imageBytes != null) {
      final hash = _computeHash(_imageBytes!);
      if (_savedImageHash == hash) {
        _snack('This image was already saved. Scan a new photo.',
            const Color(0xFFD97706));
        return;
      }
      final existing   = await LocalDB.getIncidents();
      final alreadySaved = existing.any(
          (inc) => inc['imageHash']?.toString() == hash);
      if (alreadySaved) {
        if (!mounted) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: Theme.of(context).colorScheme.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            title: const Row(children: [
              Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFD97706), size: 22),
              SizedBox(width: 8),
              Text('Duplicate Image',
                style: TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w700)),
            ]),
            content: const Text(
              'This image was already saved as a report.\n'
              'Save again as a new entry?',
              style: TextStyle(fontSize: 13, height: 1.5)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.grey))),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD97706)),
                child: const Text('Save Anyway',
                    style: TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w700))),
            ]));
        if (confirm != true) return;
      }
    }

    final user  = await LocalDB.getCurrentUser() ?? {};
    final incident = _buildIncident(user);
    final dbInc    = Map<String, dynamic>.from(incident);
    dbInc['hazards'] = jsonEncode(incident['hazards']);

    if (_imageBytes != null) {
      final hash         = _computeHash(_imageBytes!);
      dbInc['imageHash'] = hash;
      _savedImageHash    = hash;

      // Persist the FULL image to file storage so it survives the
      // imageBase64 purge and is available later for the PDF (with bbox
      // overlays) and the detail view. On web there's no file system, so we
      // keep the inline base64 which the web build tolerates.
      if (!kIsWeb) {
        try {
          final ref = await ImageStorage.saveImage(
              dbInc['id']?.toString() ?? '', _imageBytes!);
          if (ref != null) dbInc['imageRef'] = ref;
        } catch (_) {}
      } else {
        dbInc['imageBase64'] = base64Encode(_imageBytes!);
      }
    }

    await LocalDB.saveIncident(dbInc);
    SyncService.pushIncident(dbInc).catchError((_) => false);
    _uploadPdfBackground(dbInc, user);

    // ★ v35: Trigger background AI audit (silently cross-verifies with another model)
    if (_imageBytes != null && _result != null) {
      final primarySource = _result!['_source']?.toString() ?? 'unknown';
      // Build incident with parsed hazards for comparison
      final auditIncident = Map<String, dynamic>.from(dbInc);
      if (incident['hazards'] is List) {
        auditIncident['hazards'] = incident['hazards'];
      }
      AiAuditService.auditIncident(
        incident: auditIncident,
        imageBytes: _imageBytes!,
        primarySource: primarySource,
      );  // Fire-and-forget — no await
    }

    // ★ AI correction feedback loop: if the user edited the AI's output, record
    // each changed field so an admin can later decide whether the AI was wrong
    // (→ training data) or the user just preferred different wording.
    if (_originalAiResult != null && _result != null) {
      final incId = dbInc['id']?.toString() ?? '';
      AiCorrectionService.recordResultEdits(
        incidentId: incId,
        incidentType: 'AI_SCAN',
        original: _originalAiResult!,
        edited: _result!,
        imageHash: _savedImageHash ?? '',
        plant: (user['plant'] ?? '').toString(),
        editedBy: (user['name'] ?? user['username'] ?? '').toString(),
        aiSource: _result!['_source']?.toString() ?? '',
        // Pass the image so a removed hazard (false positive) can be fed to
        // training immediately without waiting for admin review.
        imageBase64: _imageBytes != null ? base64Encode(_imageBytes!) : '',
      ).catchError((_) => 0); // Fire-and-forget — never block the save.
    }

    setState(() {
      _isSaved         = true;
      _savedIncidentId = dbInc['id']?.toString();
      _currentStep     = 5;
    });

    if (mounted) {
      _showSaveSuccessDialog(dbInc);
    }
  }

  void _showSaveSuccessDialog(Map<String, dynamic> incident) {
    final sl = SL.of(context);
    final id = incident['id']?.toString() ?? '';
    final shortId = id.length > 8 ? id.substring(id.length - 8) : id;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: sl.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 70, height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0xFF10B981), Color(0xFF059669)]),
                boxShadow: [BoxShadow(
                  color: AppColors.green.withOpacity(0.3),
                  blurRadius: 16, spreadRadius: 2)]),
              child: const Icon(Icons.check_rounded,
                  color: Colors.white, size: 40)),
            const SizedBox(height: 14),
            Text('Report Saved Successfully',
                style: TextStyle(color: sl.text1, fontSize: 17,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Report ID: #$shortId',
                style: TextStyle(color: sl.text3, fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: sl.card2,
                borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                _saveRow(Icons.save_outlined, 'Saved locally',
                    'Available offline', AppColors.green, sl),
                const SizedBox(height: 8),
                _saveRow(Icons.cloud_upload_outlined, 'Synced to Google Sheets',
                    'Visible to admin', AppColors.cyan, sl),
                const SizedBox(height: 8),
                _saveRow(Icons.picture_as_pdf_outlined, 'PDF report',
                    'Uploading in background', AppColors.amber, sl),
              ])),
            const SizedBox(height: 16),
            // Share buttons row
            Row(children: [
              Expanded(child: _shareBtn(
                iconWidget: _whatsAppIcon(20),
                label: 'WhatsApp',
                color: const Color(0xFF25D366),
                onTap: () { Navigator.pop(ctx); _shareViaWhatsApp(incident); },
              )),
              const SizedBox(width: 8),
              Expanded(child: _shareBtn(
                icon: Icons.email_outlined,
                label: 'Email',
                color: const Color(0xFF1976D2),
                onTap: () { Navigator.pop(ctx); _shareViaEmail(incident); },
              )),
              const SizedBox(width: 8),
              Expanded(child: _shareBtn(
                icon: Icons.share_rounded,
                label: 'More',
                color: AppColors.accent,
                onTap: () { Navigator.pop(ctx); _shareGeneric(incident); },
              )),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () { Navigator.pop(ctx); _openSheetsLink(); },
                icon: const Icon(Icons.open_in_new_rounded,
                    size: 14, color: AppColors.accent),
                label: const Text('View Sheet',
                    style: TextStyle(color: AppColors.accent,
                        fontSize: 12, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.accent, width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              )),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.check_rounded,
                    size: 14, color: Colors.white),
                label: const Text('Done',
                    style: TextStyle(color: Colors.white,
                        fontSize: 12, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _saveRow(IconData icon, String title, String sub, Color color, SL sl) {
    return Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: color, size: 15)),
      const SizedBox(width: 10),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(
            color: sl.text1, fontSize: 12,
            fontWeight: FontWeight.w700)),
        Text(sub, style: TextStyle(color: sl.text4, fontSize: 10)),
      ])),
      Icon(Icons.check_circle, color: color, size: 16),
    ]);
  }

  // ─── SHARE HELPERS ───────────────────────────────────────────
  Widget _shareBtn({IconData? icon, Widget? iconWidget, required String label,
      required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.4))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          iconWidget ?? Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10,
              fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Widget _whatsAppIcon(double size) {
    return Container(
      width: size, height: size,
      decoration: const BoxDecoration(
        color: Color(0xFF25D366),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.phone, color: Colors.white, size: size * 0.6),
    );
  }

  String _buildShareText(Map<String, dynamic> incident) {
    final title    = incident['title']?.toString() ?? 'AI Hazard Scan';
    final severity = incident['severity']?.toString() ?? 'MEDIUM';
    final plant    = incident['plant']?.toString() ?? '';
    final summary  = incident['summary']?.toString() ?? '';
    final hazards  = incident['hazards'];
    final hazardCount = hazards is List ? hazards.length : 0;
    final date     = incident['date']?.toString().split('T').first ?? '';

    return '🚨 *SAIL Safety Lens — Hazard Report*\n\n'
        '📋 *Title:* $title\n'
        '⚠️ *Risk Level:* $severity\n'
        '🏭 *Plant:* $plant\n'
        '📅 *Date:* $date\n'
        '🔍 *Hazards Found:* $hazardCount\n\n'
        '📝 *Summary:*\n$summary\n\n'
        '—\n_Generated by SAIL Safety Lens AI_';
  }

  Future<void> _shareViaWhatsApp(Map<String, dynamic> incident) async {
    // ★ v22: Share PDF link via WhatsApp (not plain text)
    String? pdfUrl = incident['pdfUrl']?.toString();

    if (pdfUrl == null || pdfUrl.isEmpty) {
      _snack('Generating PDF...', AppColors.accent);
      try {
        final user = await LocalDB.getCurrentUser();
        final pdfBytes = await PdfExport.generateIncidentReportBytes(
          incident:     incident,
          reporterName: user?['name']?.toString() ?? 'SAIL Safety Officer',
          reporterPno:  user?['pno']?.toString()  ?? '',
          imageBytes:   _imageBytes,
        );
        if (pdfBytes.isNotEmpty) {
          pdfUrl = await SyncService.uploadPdfToDrive(
            incidentId: incident['id']?.toString() ?? '',
            pdfBytes:   pdfBytes,
            fileName:   'SafetyLens_${incident['id']}.pdf',
          );
        }
      } catch (e) {
        print('WhatsApp PDF share error: $e');
      }
    }

    final title    = incident['title']?.toString() ?? 'Hazard Report';
    final severity = incident['severity']?.toString() ?? 'MEDIUM';
    final plant    = incident['plant']?.toString() ?? '';
    final date     = incident['date']?.toString().split('T').first ?? '';

    String text;
    if (pdfUrl != null && pdfUrl.isNotEmpty) {
      text = '⚠️ *SAIL Safety Lens — Hazard Report*\n\n'
          '📋 *Title:* $title\n'
          '🔴 *Severity:* $severity\n'
          '🏭 *Plant:* $plant\n'
          '📅 *Date:* $date\n\n'
          '📄 *Full PDF Report:*\n$pdfUrl\n\n'
          '—\n_Generated by SAIL Safety Lens_';
    } else {
      text = _buildShareText(incident);
    }

    // ★ v32: Use native share — wa.me opens new browser tabs every time
    await Share.share(text, subject: 'Safety Lens Report — ${incident['plant'] ?? ''}');
  }

  Future<void> _shareViaEmail(Map<String, dynamic> incident) async {
    final text    = _buildShareText(incident);
    final title   = incident['title']?.toString() ?? 'Hazard Report';
    final subject = 'SAIL Safety Lens: $title';
    final url = Uri(scheme: 'mailto', query: 'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(text)}');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else {
        await Share.share(text, subject: subject);
      }
    } catch (_) {
      await Share.share(text, subject: subject);
    }
  }

  Future<void> _shareGeneric(Map<String, dynamic> incident) async {
    final text = _buildShareText(incident);
    await Share.share(text);
  }

  // ─── STEP 5: MITIGATE ────────────────────────────────────────
  void _openMitigateSheet() {
    if (_result == null) return;
    if (!_isSaved) {
      _snack('Save the scan first (Step 4) before mitigating',
          AppColors.amber);
      return;
    }
    setState(() => _currentStep = 5);
    final hazards = (_result!['hazards'] as List?) ?? [];
    final sl      = SL.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => DraggableScrollableSheet(
          initialChildSize: 0.88,
          maxChildSize: 0.97,
          minChildSize: 0.5,
          builder: (_, ctrl) => Container(
            decoration: BoxDecoration(
              color: sl.isDark ? const Color(0xFF1C1F2E) : Colors.white,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20))),
            child: Column(children: [
              Center(child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: sl.border,
                    borderRadius: BorderRadius.circular(99)))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Row(children: [
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.purple.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.engineering_rounded,
                        color: AppColors.purple, size: 16)),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    Text('Mitigate Hazards',
                      style: TextStyle(color: sl.text1,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                    Text('Add corrective action per hazard & close',
                      style: TextStyle(color: sl.text4, fontSize: 10)),
                  ])),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(Icons.close, color: sl.text4, size: 20),
                    onPressed: () => Navigator.pop(ctx)),
                ])),
              Divider(height: 1, color: sl.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Text(
                    '${_hazardClosed.values.where((v) => v).length}'
                    ' / ${hazards.length} closed',
                    style: TextStyle(color: sl.text4, fontSize: 11)),
                  const SizedBox(width: 10),
                  Expanded(child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: hazards.isEmpty ? 0
                          : _hazardClosed.values.where((v) => v).length
                              / hazards.length,
                      minHeight: 6,
                      backgroundColor: sl.border.withOpacity(0.3),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.green)))),
                ])),
              Expanded(child: ListView.separated(
                controller: ctrl,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                itemCount: hazards.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final h      = Map<String, dynamic>.from(hazards[i] as Map);
                  final sc     = _sevColor(
                      h['severity']?.toString() ?? 'MEDIUM');
                  final closed = _hazardClosed[i] ?? false;
                  final ctrl2  = _mitigationControllers[i]!;

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: closed
                          ? AppColors.green.withOpacity(0.05)
                          : (sl.isDark
                              ? const Color(0xFF252840) : Colors.white),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: closed
                            ? AppColors.green.withOpacity(0.5)
                            : sc.withOpacity(0.35),
                        width: closed ? 1.5 : 1)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      Row(children: [
                        Container(
                          width: 20, height: 20,
                          decoration: BoxDecoration(
                            color: closed ? AppColors.green : sc,
                            shape: BoxShape.circle),
                          child: Center(child: closed
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 11)
                            : Text('${i+1}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 9,
                                    fontWeight: FontWeight.w800)))),
                        const SizedBox(width: 8),
                        Expanded(child: Text(
                          h['name']?.toString() ?? '—',
                          style: TextStyle(
                            color: closed ? sl.text3 : sl.text1,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            decoration: closed
                                ? TextDecoration.lineThrough : null))),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: sc.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: sc)),
                          child: Text(
                            (h['severity']?.toString() ?? '—').substring(0,
                                  (h['severity']?.toString().length ?? 4)
                                  .clamp(0, 4)),
                            style: TextStyle(color: sc,
                                fontSize: 7, fontWeight: FontWeight.w800))),
                      ]),
                      if (!closed) ...[
                        const SizedBox(height: 6),
                        if ((h['correctiveAction']?.toString() ?? '').isNotEmpty)
                          Container(
                            padding: const EdgeInsets.all(7),
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                  color: AppColors.accent.withOpacity(0.25))),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                              const Text('🔧 ', style: TextStyle(fontSize: 10)),
                              Expanded(child: Text(
                                'AI suggests: ${h['correctiveAction']}',
                                style: const TextStyle(
                                    color: AppColors.accent,
                                    fontSize: 9, height: 1.4))),
                            ])),
                        Text('Your corrective action / comment:',
                          style: TextStyle(color: sl.text3, fontSize: 10,
                              fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: ctrl2,
                          maxLines: 2,
                          style: TextStyle(color: sl.text1, fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Describe what was done…',
                            hintStyle: TextStyle(color: sl.text4, fontSize: 11),
                            filled: true,
                            fillColor: sl.isDark
                                ? const Color(0xFF1C1F2E)
                                : const Color(0xFFF5F6FA),
                            contentPadding: const EdgeInsets.all(10),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(9),
                              borderSide: BorderSide(
                                  color: sl.border.withOpacity(0.4))),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(9),
                              borderSide: const BorderSide(
                                  color: AppColors.green, width: 2)))),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              if (ctrl2.text.trim().isEmpty) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                  content: Text('Add a comment first'),
                                  backgroundColor: Color(0xFFD97706)));
                                return;
                              }
                              setLocal(() {
                                _hazardClosed[i] = true;
                              });
                              setState(() {
                                _hazardClosed[i] = true;
                              });
                              _saveHazardMitigation(i, h, ctrl2.text.trim());
                            },
                            icon: const Icon(Icons.lock_rounded,
                                size: 14, color: Colors.white),
                            label: const Text('Close this hazard',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.green,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(9))))),
                      ] else ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.green.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppColors.green.withOpacity(0.3))),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                            const Icon(Icons.check_circle_outline,
                                color: AppColors.green, size: 14),
                            const SizedBox(width: 6),
                            Expanded(child: Text(
                              ctrl2.text.isNotEmpty
                                  ? ctrl2.text : 'Hazard closed',
                              style: const TextStyle(
                                  color: AppColors.green,
                                  fontSize: 11, height: 1.4))),
                          ])),
                      ],
                    ]));
                })),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                child: Column(children: [
                  if (_hazardClosed.values.every((v) => v) && hazards.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.green.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppColors.green.withOpacity(0.4))),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                          Icon(Icons.celebration_rounded,
                              color: AppColors.green, size: 18),
                          SizedBox(width: 8),
                          Text('All hazards mitigated!',
                            style: TextStyle(
                                color: AppColors.green,
                                fontSize: 13,
                                fontWeight: FontWeight.w700)),
                        ]))),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      onPressed: _openSheetsLink,
                      icon: const Icon(Icons.table_chart_rounded,
                          size: 14, color: AppColors.accent),
                      label: const Text('View in Sheets',
                        style: TextStyle(
                            color: AppColors.accent,
                            fontSize: 12, fontWeight: FontWeight.w700)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: AppColors.accent, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10))),
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.done_all_rounded,
                          size: 14, color: Colors.white),
                      label: const Text('Done',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12, fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.purple,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10))),
                    )),
                  ]),
                ])),
            ])))));
  }

  Future<void> _saveHazardMitigation(
      int idx, Map<String, dynamic> hazard, String comment) async {
    if (_savedIncidentId == null) return;
    final all = await LocalDB.getIncidents();
    final incIdx = all.indexWhere(
        (i) => i['id']?.toString() == _savedIncidentId);
    if (incIdx < 0) return;

    dynamic rawHazards = all[incIdx]['hazards'];
    List hazards = [];
    if (rawHazards is String) {
      try { hazards = jsonDecode(rawHazards); } catch (_) {}
    } else if (rawHazards is List) {
      hazards = rawHazards;
    }

    if (idx < hazards.length) {
      final updated = Map<String, dynamic>.from(hazards[idx] as Map);
      updated['mitigationComment'] = comment;
      updated['mitigatedAt']       = DateTime.now().toIso8601String();
      updated['mitigated']         = true;
      hazards[idx] = updated;
    }

    all[incIdx]['hazards'] = jsonEncode(hazards);
    final allClosed = _hazardClosed.values.every((v) => v);
    if (allClosed) {
      all[incIdx]['status']   = 'CLOSED';
      all[incIdx]['closedAt'] = DateTime.now().toIso8601String();
    }

    await LocalDB.saveIncident(all[incIdx]);
    SyncService.pushIncident(all[incIdx]).catchError((_) => false);
  }

  Future<void> _openSheetsLink() async {
    final uri = Uri.parse(_sheetUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _snack('Could not open browser', AppColors.red);
      }
    } catch (e) {
      _snack('Error: $e', AppColors.red);
    }
  }

  Map<String, dynamic> _buildIncident(Map<String, dynamic> user) {
    final hazards        = (_result!['hazards'] as List?) ?? [];
    // ✅ FIX: Safe access to first hazard — guard against null/non-Map entries
    Map<String, dynamic> firstHazardMap = <String, dynamic>{};
    String firstHazard = 'AI Hazard Scan';
    if (hazards.isNotEmpty && hazards.first is Map) {
      try {
        firstHazardMap = Map<String, dynamic>.from(hazards.first as Map);
        firstHazard = firstHazardMap['name']?.toString() ?? 'AI Hazard Scan';
      } catch (_) {}
    }

    // Build base incident
    // ★ v35: Include detected section for department-wise alerts & analytics
    final detectedSection = _result!['detectedSection']?.toString() ?? 'GENERAL';
    final sectionCues = _result!['sectionCues']?.toString() ?? '';

    final incident = {
      'id':              DateTime.now().millisecondsSinceEpoch.toString(),
      'title':           'AI Hazard Scan: ${firstHazard.toString()}',
      'plant':           user['plant']?.toString() ?? 'SAIL Safety Organisation',
      'dept':            user['department']?.toString().isNotEmpty == true
                         ? user['department'].toString()
                         : detectedSection,
      'detectedSection': detectedSection,
      'sectionCues':     sectionCues,
      'location':        'AI scan result — $detectedSection',
      'severity':        _result!['overallRisk'] ?? 'MEDIUM',
      'wsaCategory':     firstHazardMap['wsaCause']?.toString() ?? 'Multiple causes',
      'obsType':         'N/A',
      'summary':         _result!['summary']?.toString() ?? '',
      'desc':            _result!['summary']?.toString() ?? '',
      'immediateAction': firstHazardMap['correctiveAction']?.toString()
                         ?? 'Investigate per IS 14489:2018',
      'type':            'AI_SCAN',
      'status':          'OPEN',
      'date':            DateTime.now().toIso8601String(),
      'reportedBy':      user['name']?.toString() ?? 'SAIL Safety Officer',
      'reportedByPno':   user['pno']?.toString()  ?? '',
      'people':          '0',
      'hazards':         hazards,
      'riskScore':       _result!['riskScore']    ?? 0,
      'confidence':      _result!['confidence']   ?? 0,
      'ptw_required':    _result!['ptw_required']?.toString() ?? 'None',
      'section_specific_risks': _result!['section_specific_risks'] ?? [],
      'imageBase64':     _imageBytes != null
                         ? base64Encode(_imageBytes!) : null,
      'thumbnailBase64': _imageBytes != null
                         ? _generateThumbnail(_imageBytes!) : null,
    };

    // ✅ Add GPS location data if available
    if (_capturedLocation != null && _capturedLocation!.isValid) {
      incident['latitude'] = _capturedLocation!.latitude;
      incident['longitude'] = _capturedLocation!.longitude;
      incident['locationAccuracy'] = _capturedLocation!.accuracy;
      incident['locationAddress'] = _capturedLocation!.address;
      incident['locationTimestamp'] = _capturedLocation!.timestamp.toIso8601String();
    }

    return incident;
  }

  /// ★ Generate a tiny thumbnail (60px wide) for the incident log card
  /// Stored as base64 JPEG — typically 2-4KB (safe for localStorage)
  String? _generateThumbnail(Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;
      final thumb = img.copyResize(decoded, width: 60);
      final jpgBytes = img.encodeJpg(thumb, quality: 50);
      return base64Encode(jpgBytes);
    } catch (e) {
      print('Thumbnail generation failed: $e');
      return null;
    }
  }

  Future<void> _uploadPdfBackground(
      Map<String, dynamic> incident, Map<String, dynamic> user) async {
    try {
      print('PDF Upload: generating PDF for incident ${incident['id']}...');
      final pdfBytes = await PdfExport.generateIncidentReportBytes(
        incident:     incident,
        reporterName: user['name']?.toString() ?? 'SAIL Safety Officer',
        reporterPno:  user['pno']?.toString()  ?? '',
        imageBytes:   _imageBytes,
      );
      if (pdfBytes.isEmpty) {
        print('PDF Upload: FAILED — empty PDF bytes');
        return;
      }
      print('PDF Upload: generated ${pdfBytes.length} bytes, uploading to Drive...');

      // Wait to ensure: (1) incident row exists in sheet, (2) no AI call contention
      await Future.delayed(const Duration(seconds: 8));

      final url = await SyncService.uploadPdfToDrive(
        incidentId: incident['id']?.toString() ?? '',
        pdfBytes:   pdfBytes,
        fileName:   'SafetyLens_${incident['id']}.pdf',
      );
      if (url != null && url.isNotEmpty) {
        print('PDF Upload: SUCCESS — $url');
        // Update the incident with the PDF URL
        await SyncService.pushIncident({
          'id': incident['id'],
          'pdfUrl': url,
        }).catchError((e) {
          print('PDF Upload: pushIncident failed — $e');
          return false;
        });
      } else {
        print('PDF Upload: uploadPdfToDrive returned null/empty URL');
      }
    } catch (e) {
      print('PDF Upload: EXCEPTION — $e');
    }
  }

  Future<void> _exportPdf() async {
    if (_result == null) return;
    final user     = await LocalDB.getCurrentUser() ?? {};
    final incident = _buildIncident(user);
    try {
      _snack('Generating PDF…', AppColors.accent);
      await PdfExport.downloadOrShareIncident(
        incident:     incident,
        reporterName: user['name']?.toString() ?? 'SAIL Safety Officer',
        reporterPno:  user['pno']?.toString()  ?? '',
        imageBytes:   _imageBytes,
      );
      if (mounted) _snack(
          kIsWeb ? 'PDF downloaded' : 'PDF ready to share',
          AppColors.green);
    } catch (e) {
      if (mounted) _snack('PDF failed: $e', AppColors.red);
    }
  }

  void _shareReport() {
    if (_result == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Share Report',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _shareOption(
                  icon: Icons.chat_rounded,
                  color: const Color(0xFF25D366),
                  label: 'WhatsApp',
                  onTap: () { Navigator.pop(context); _shareResultWhatsApp(); },
                ),
                _shareOption(
                  icon: Icons.email_rounded,
                  color: const Color(0xFF1976D2),
                  label: 'Email',
                  onTap: () { Navigator.pop(context); _shareResultEmail(); },
                ),
                _shareOption(
                  icon: Icons.more_horiz_rounded,
                  color: Colors.grey[700]!,
                  label: 'Other',
                  onTap: () { Navigator.pop(context); _shareResultGeneric(); },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _shareOption({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(
          color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  String _buildResultShareText() {
    final hazards = (_result!['hazards'] as List?) ?? [];
    final risk = _result!['overallRisk']?.toString() ?? 'UNKNOWN';
    final score = _result!['riskScore'] ?? 0;
    final buffer = StringBuffer();
    buffer.writeln('🔴 SAIL SAFETY LENS — HAZARD REPORT');
    buffer.writeln('━━━━━━━━━━━━━━━━━━━━━━━━');
    buffer.writeln('⚠️ Overall Risk: $risk (Score: $score/100)');
    buffer.writeln('📊 Hazards Found: ${hazards.length}');
    buffer.writeln('');
    for (int i = 0; i < hazards.length; i++) {
      final h = Map<String, dynamic>.from(hazards[i] as Map);
      final sev = h['severity']?.toString() ?? 'MEDIUM';
      final icon = sev == 'CRITICAL' ? '🔴' : sev == 'HIGH' ? '🟠' : sev == 'MEDIUM' ? '🟡' : '🟢';
      buffer.writeln('$icon ${i+1}. ${h['name'] ?? 'Hazard'} [$sev]');
      buffer.writeln('   ${h['description'] ?? ''}');
      buffer.writeln('   ✅ Action: ${h['correctiveAction'] ?? 'N/A'}');
      buffer.writeln('');
    }
    buffer.writeln('━━━━━━━━━━━━━━━━━━━━━━━━');
    buffer.writeln('Generated by SAIL Safety Lens');
    return buffer.toString();
  }

  Future<void> _shareResultWhatsApp() async {
    // ★ v22: Generate PDF and share link via WhatsApp
    String? pdfUrl;
    try {
      _snack('Generating PDF...', AppColors.accent);
      final user = await LocalDB.getCurrentUser() ?? {};
      final incident = _buildIncident(user);
      final pdfBytes = await PdfExport.generateIncidentReportBytes(
        incident:     incident,
        reporterName: user['name']?.toString() ?? 'SAIL Safety Officer',
        reporterPno:  user['pno']?.toString()  ?? '',
        imageBytes:   _imageBytes,
      );
      if (pdfBytes.isNotEmpty) {
        pdfUrl = await SyncService.uploadPdfToDrive(
          incidentId: incident['id']?.toString() ?? '',
          pdfBytes:   pdfBytes,
          fileName:   'SafetyLens_${incident['id']}.pdf',
        );
      }
    } catch (e) {
      print('WhatsApp PDF share error: $e');
    }

    String text;
    if (pdfUrl != null && pdfUrl.isNotEmpty) {
      final hazards = (_result!['hazards'] as List?) ?? [];
      final risk = _result!['overallRisk']?.toString() ?? 'UNKNOWN';
      final score = _result!['riskScore'] ?? 0;
      text = '⚠️ *SAIL Safety Lens — AI Hazard Report*\n\n'
          '🔴 *Overall Risk:* $risk (Score: $score/100)\n'
          '📊 *Hazards Found:* ${hazards.length}\n\n'
          '📄 *Full PDF Report:*\n$pdfUrl\n\n'
          '—\n_Generated by SAIL Safety Lens_';
    } else {
      // Fallback to text if PDF failed
      text = _buildResultShareText();
    }

    // ★ v32: Use native share — wa.me opens new browser tabs every time
    await Share.share(text, subject: 'SAIL Safety Lens - Hazard Report');
  }

  Future<void> _shareResultEmail() async {
    final text = _buildResultShareText();
    final subject = Uri.encodeComponent('SAIL Safety Lens - Hazard Report');
    final body = Uri.encodeComponent(text);
    final emailUrl = 'mailto:?subject=$subject&body=$body';
    try {
      final uri = Uri.parse(emailUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        await Share.share(text, subject: 'SAIL Safety Lens - Hazard Report');
      }
    } catch (e) {
      _snack('Could not open email: $e', AppColors.red);
    }
  }

  Future<void> _shareResultGeneric() async {
    final text = _buildResultShareText();
    await Share.share(text, subject: 'SAIL Safety Lens - Hazard Report');
  }

  void _reset() {
    for (final c in _mitigationControllers.values) { c.dispose(); }
    _mitigationControllers.clear();
    _hazardClosed.clear();
    setState(() {
      _pickedFile      = null; _imageBytes = null;
      _result          = null; _analyzing  = false;
      _hazardRowKeys.clear(); _highlightedRow = null;
      _isSaved         = false; _savedIncidentId = null;
      _currentStep     = 0;
    });
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
    ));
  }

  // ─────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Container(
      color: Colors.transparent,
      child: SafeArea(child: Column(children: [
        if (widget.showAppBar)
          UniversalAppBar(
            title: I18n.t('aiScan.title'),
            subtitle: I18n.t('aiScan.subtitle'),
            user: widget.user,
            toggleTheme: widget.toggleTheme,
            onSignOut: widget.onSignOut,
            isDark: widget.isDark,
          ),
        Expanded(child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 80),
          child: _analyzing
              ? _analyzingView()
              : _result != null
                  ? _resultView(sl)
                  : _emptyView(sl),
        )),
      ])));
  }

  Widget _emptyView(SL sl) {
    final cardBg = sl.isDark ? const Color(0xFF252840) : Colors.white;
    return Column(children: [
      GestureDetector(
        onTap: () => _pickImage(ImageSource.camera),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: cardBg,
            border: Border.all(
                color: AppColors.accent.withOpacity(0.3), width: 2),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(sl.isDark ? 0.2 : 0.04),
              blurRadius: 8, offset: const Offset(0, 2))]),
          child: Column(children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.1),
                shape: BoxShape.circle),
              child: const Icon(Icons.add_a_photo_outlined,
                  size: 32, color: AppColors.accent)),
            const SizedBox(height: 12),
            Text('Capture workplace photo',
              style: TextStyle(color: sl.text1, fontSize: 14,
                  fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('AI detects hazards & marks them on photo',
              style: TextStyle(color: sl.text4, fontSize: 11)),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 4, children: [
              _featureTag('🎯 Bbox mapping', sl),
              _featureTag('⚖️ IS 14489', sl),
              _featureTag('🏭 WSA 13', sl),
              _featureTag('📋 PDF export', sl),
              _featureTag('📊 Sheets sync', sl),
            ]),
          ])),
      ),
      const SizedBox(height: 12),
      VoiceTextField(
        controller: _locationController,
        label: 'Location',
        hint: 'e.g. BF-2 Cast House, Bay 4',
        maxLines: 1,
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: ElevatedButton.icon(
          onPressed: () => _pickImage(ImageSource.camera),
          icon: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
          label: const Text('Camera', style: TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: AppColors.accentDark, width: 2))),
        )),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(
          onPressed: () => _pickImage(ImageSource.gallery),
          icon: const Icon(Icons.photo_library,
              size: 14, color: AppColors.accent),
          label: const Text('Gallery', style: TextStyle(
              color: AppColors.accent, fontSize: 12,
              fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.accent, width: 2),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
      ]),
      const SizedBox(height: 14),
      _infoBox(sl),
    ]);
  }

  Widget _featureTag(String label, SL sl) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.accent.withOpacity(0.07),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: AppColors.accent.withOpacity(0.2))),
    child: Text(label, style: const TextStyle(
        color: AppColors.accent, fontSize: 9,
        fontWeight: FontWeight.w600)));

  Widget _analyzingView() => Container(
    height: 160,
    decoration: BoxDecoration(
      color: const Color(0xFF252840),
      borderRadius: BorderRadius.circular(12),
      image: _imageBytes != null ? DecorationImage(
          image: MemoryImage(_imageBytes!),
          fit: BoxFit.cover) : null),
    child: Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12)),
      child: Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
        const CircularProgressIndicator(strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent)),
        const SizedBox(height: 10),
        Text(_step, style: const TextStyle(
          color: Colors.white, fontSize: 12,
          fontWeight: FontWeight.w600)),
      ]))));

  static const Map<String, int> _sevOrder = {
    'CRITICAL': 0, 'HIGH': 1, 'MEDIUM': 2, 'LOW': 3,
  };

  /// Small pill showing whether the analysis came from the live online AI
  /// or the offline knowledge-base fallback. Reads the flags GeminiVision
  /// attaches to every result (`_isOnline`, `_offline_reason`, `_fromCache`).
  Widget _analysisSourceBadge(SL sl) {
    final online     = _result?['_isOnline'] == true;
    final fromCache  = _result?['_fromCache'] == true;
    final reason     = _result?['_offline_reason']?.toString() ?? '';

    final Color color = online ? AppColors.green : AppColors.amber;
    final IconData icon = online
        ? Icons.cloud_done_outlined
        : Icons.cloud_off_outlined;
    final String label = online
        ? (fromCache ? 'Online AI Analysis (cached)' : 'Online AI Analysis')
        : 'Offline Analysis — limited';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
            if (!online) Text(
              reason.isNotEmpty
                  ? 'AI unavailable — showing example guidance. Connect to the internet and rescan for a real assessment.'
                  : 'Showing example guidance. Connect to the internet and rescan for a real assessment.',
              style: TextStyle(color: sl.text3, fontSize: 9.5, fontWeight: FontWeight.w500)),
          ],
        )),
      ]),
    );
  }

  Widget _resultView(SL sl) {
    final overallRisk = _result!['overallRisk']?.toString() ?? 'MEDIUM';
    final score       = _result!['riskScore']    ?? 50;
    final confidence  = _result!['confidence']   ?? 75;
    final summary     = _result!['summary']?.toString() ?? '';
    final hazards     = List<dynamic>.from((_result!['hazards'] as List?) ?? []);
    // Sort hazards by severity: CRITICAL > HIGH > MEDIUM > LOW
    hazards.sort((a, b) {
      final sa = _sevOrder[(a as Map)['severity']?.toString().toUpperCase() ?? 'MEDIUM'] ?? 3;
      final sb = _sevOrder[(b as Map)['severity']?.toString().toUpperCase() ?? 'MEDIUM'] ?? 3;
      return sa.compareTo(sb);
    });
    final riskColor   = _sevColor(overallRisk);
    final hasBbox     = hazards.any((h) {
      final bbox = (h as Map)['bbox'];
      if (bbox == null) return false;
      if (bbox is Map && bbox.isEmpty) return false;
      if (bbox is Map) {
        final w = num.tryParse(bbox['w']?.toString() ?? bbox['width']?.toString() ?? '0') ?? 0;
        final h = num.tryParse(bbox['h']?.toString() ?? bbox['height']?.toString() ?? '0') ?? 0;
        return (w > 0 && h > 0);
      }
      if (bbox is List && bbox.length >= 4) return true;
      return false;
    });
    final cardBg      = sl.isDark ? const Color(0xFF252840) : Colors.white;

    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

      // ★ Online/offline source badge — makes it obvious whether this report
      // came from the live AI or the offline knowledge-base fallback.
      _analysisSourceBadge(sl),

      if (_isSaved) Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.green.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.green.withOpacity(0.4))),
        child: Row(children: [
          const Icon(Icons.check_circle_outline,
              color: AppColors.green, size: 16),
          const SizedBox(width: 8),
          const Expanded(child: Text('Saved & synced to Sheets',
            style: TextStyle(color: AppColors.green,
                fontSize: 11, fontWeight: FontWeight.w600))),
          GestureDetector(
            onTap: _openSheetsLink,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.green,
                borderRadius: BorderRadius.circular(6)),
              child: const Text('View Sheet →',
                style: TextStyle(color: Colors.white,
                    fontSize: 10, fontWeight: FontWeight.w700)))),
        ])),

      if (_imageBytes != null) ...[
        Container(
          constraints: const BoxConstraints(maxHeight: 320),
          decoration: BoxDecoration(
            color: sl.isDark
                ? const Color(0xFF1A1D2E)
                : const Color(0xFFF8F9FB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sl.border.withOpacity(0.35)),
          ),
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: HazardAnnotatedImage(
                imageBytes: _imageBytes!,
                hazards: hazards,
                onHazardTap: _onBboxTap),
          ),
        ),

        // ✅ NEW: Hazard Map Legend — numbered chips below the image.
        // Each chip = number + severity colour + hazard name.
        // Tapping a chip highlights that hazard's row in the table below,
        // exactly like tapping the corresponding box on the image.
        if (hasBbox) ...[
          const SizedBox(height: 8),
          _hazardLegendStrip(hazards, sl),
        ],
        const SizedBox(height: 10),
      ],

      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: riskColor.withOpacity(0.06),
          border: Border.all(color: riskColor, width: 2),
          borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              color: riskColor.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(color: riskColor, width: 2.5)),
            child: Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
              Text('$score', style: TextStyle(
                color: riskColor, fontSize: 20,
                fontWeight: FontWeight.w800)),
              Text('/100', style: TextStyle(
                color: riskColor, fontSize: 8)),
            ]))),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text('OVERALL RISK', style: TextStyle(
              color: sl.text4, fontSize: 9,
              fontWeight: FontWeight.w600)),
            Text(overallRisk, style: TextStyle(
              color: riskColor, fontSize: 18,
              fontWeight: FontWeight.w800)),
            Text('${hazards.length} hazards · $confidence% confidence',
              style: TextStyle(color: sl.text3, fontSize: 10)),
            if (hasBbox)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Tap boxes on image → jumps to row',
                  style: TextStyle(color: AppColors.accent,
                      fontSize: 9, fontStyle: FontStyle.italic))),
          ])),
        ])),
      const SizedBox(height: 10),

      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardBg,
          border: Border.all(color: sl.border.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(sl.isDark ? 0.15 : 0.04),
            blurRadius: 6, offset: const Offset(0, 2))]),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text('SUMMARY', style: TextStyle(
            color: sl.text4, fontSize: 9,
            fontWeight: FontWeight.w700, letterSpacing: 0.9)),
          const SizedBox(height: 6),
          Text(summary, style: TextStyle(
            color: sl.text2, fontSize: 11, height: 1.5)),
        ])),
      const SizedBox(height: 10),

      // ✅ FIX: Don't show hazard table when AI failed (no real hazards)
      if (hazards.isNotEmpty)
        _hazardTable(hazards, sl)
      else
        Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: AppColors.amber.withOpacity(0.06),
            border: Border.all(color: AppColors.amber.withOpacity(0.4)),
            borderRadius: BorderRadius.circular(12)),
          child: Column(
            children: [
              const Icon(Icons.cloud_off_rounded, color: AppColors.amber, size: 32),
              const SizedBox(height: 8),
              Text('AI Analysis Unavailable',
                style: TextStyle(color: sl.text1, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Server could not process this image. Tap "New" and retry when connectivity improves.',
                textAlign: TextAlign.center,
                style: TextStyle(color: sl.text3, fontSize: 11, height: 1.4)),
            ]),
        ),
      const SizedBox(height: 12),

      // ✅ v23: Two-row button layout for proper alignment
      Row(children: [
        Expanded(child: ElevatedButton.icon(
          onPressed: _result != null
              ? (_isSaved ? null : _openReviewSheet) : null,
          icon: const Icon(Icons.fact_check_outlined,
              size: 14, color: Colors.white),
          label: const Text('Review',
              style: TextStyle(color: Colors.white,
                  fontSize: 11, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.amber,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
        const SizedBox(width: 6),
        Expanded(child: ElevatedButton.icon(
          onPressed: _isSaved ? null : _save,
          icon: Icon(_isSaved ? Icons.check_rounded : Icons.save_outlined,
              size: 14, color: Colors.white),
          label: Text(_isSaved ? 'Saved ✓' : 'Save',
              style: const TextStyle(color: Colors.white,
                  fontSize: 11, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: _isSaved ? Colors.grey : AppColors.green,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
        const SizedBox(width: 6),
        Expanded(child: ElevatedButton.icon(
          onPressed: _exportPdf,
          icon: const Icon(Icons.picture_as_pdf,
              size: 14, color: Colors.white),
          label: const Text('PDF',
              style: TextStyle(color: Colors.white,
                  fontSize: 11, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
        const SizedBox(width: 6),
        Expanded(child: ElevatedButton.icon(
          onPressed: _shareReport,
          icon: const Icon(Icons.share_rounded,
              size: 14, color: Colors.white),
          label: const Text('Share',
              style: TextStyle(color: Colors.white,
                  fontSize: 11, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF25D366),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
        const SizedBox(width: 6),
        Expanded(child: OutlinedButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.refresh, size: 14, color: AppColors.accent),
          label: const Text('New',
              style: TextStyle(color: AppColors.accent,
                  fontSize: 11, fontWeight: FontWeight.w700)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.accent, width: 2),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
      ]),

      if (_isSaved) ...[
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: _openMitigateSheet,
          icon: const Icon(Icons.engineering_rounded,
              size: 14, color: Colors.white),
          label: const Text('Mitigate Hazards',
              style: TextStyle(color: Colors.white,
                  fontSize: 12, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.purple,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10))),
        )),
      ],
    ]);
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v35: HAZARD TABLE — 3-column professional layout
  //  Columns: HAZARD OBSERVED | DESCRIPTION | CORRECTIVE ACTION
  //  Severity + Type badge next to hazard name, regulation bold below
  // ═══════════════════════════════════════════════════════════════
  Widget _hazardTable(List hazards, SL sl) {
    final cardBg = sl.isDark ? const Color(0xFF252840) : Colors.white;
    final headerBg = sl.isDark ? const Color(0xFF2A2D42) : const Color(0xFFF5F6FA);
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        border: Border.all(color: sl.border.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(sl.isDark ? 0.15 : 0.04),
          blurRadius: 6, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        // Title row
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(children: [
            const Icon(Icons.table_view_outlined, size: 14, color: AppColors.red),
            const SizedBox(width: 6),
            Text('HAZARD ANALYSIS', style: TextStyle(
              color: sl.text4, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 0.9)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: AppColors.red.withOpacity(0.3))),
              child: Text('${hazards.length} hazards',
                style: const TextStyle(color: AppColors.red,
                    fontSize: 9, fontWeight: FontWeight.w700))),
          ])),
        // Column headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: headerBg,
            border: Border(
              top: BorderSide(color: sl.border.withOpacity(0.3)),
              bottom: BorderSide(color: sl.border.withOpacity(0.3)))),
          child: Row(children: [
            SizedBox(width: 28, child: Text('', style: TextStyle(fontSize: 1))),
            Expanded(flex: 3, child: Text('HAZARD',
              style: TextStyle(color: sl.text4, fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 0.5))),
            Expanded(flex: 4, child: Text('DESCRIPTION',
              style: TextStyle(color: sl.text4, fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 0.5))),
            Expanded(flex: 3, child: Text('ACTION',
              style: TextStyle(color: sl.text4, fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 0.5))),
          ]),
        ),
        // Hazard rows
        ...hazards.asMap().entries.map((entry) {
          final i   = entry.key;
          final h   = entry.value;
          final hm  = Map<String, dynamic>.from(h as Map);
          final sev = (hm['severity'] ?? 'MEDIUM').toString();
          final isH = _highlightedRow == i;
          final color = _sevColor(sev);
          final regText = hm['regulation']?.toString() ?? '';
          return Container(
            key: i < _hazardRowKeys.length ? _hazardRowKeys[i] : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: isH ? color.withOpacity(0.06) : Colors.transparent,
              border: Border(bottom: BorderSide(
                color: sl.border.withOpacity(0.2), width: 0.5))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Number badge
              Container(
                width: 22, height: 22,
                margin: const EdgeInsets.only(right: 6, top: 1),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Center(child: Text('${i+1}',
                  style: const TextStyle(
                    color: Colors.white, fontSize: 9,
                    fontWeight: FontWeight.w900)))),
              // Column 1: HAZARD (name + type/severity + regulation)
              Expanded(flex: 3, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hm['name']?.toString() ?? '',
                    style: TextStyle(color: sl.text1, fontSize: 11,
                      fontWeight: FontWeight.w700, height: 1.3)),
                  const SizedBox(height: 4),
                  // Type badge + Severity pill in a row
                  Wrap(spacing: 5, runSpacing: 4, children: [
                    if (hm['type'] != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: _typeColor(hm['type'].toString()),
                          borderRadius: BorderRadius.circular(4)),
                        child: Text(hm['type'].toString(),
                          style: TextStyle(
                            color: _typeTextColor(hm['type'].toString()),
                            fontSize: 8, fontWeight: FontWeight.w600))),
                    _sevPill(sev, color),
                  ]),
                  // Regulation — bold, light background
                  if (regText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: sl.isDark
                            ? Colors.white.withOpacity(0.05)
                            : const Color(0xFFF0F4FF),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: sl.border.withOpacity(0.3))),
                        child: Text(regText,
                          style: TextStyle(color: sl.text1, fontSize: 9.5,
                            fontWeight: FontWeight.w700, height: 1.3)),
                      )),
                ],
              )),
              const SizedBox(width: 8),
              // Column 2: DESCRIPTION
              Expanded(flex: 4, child: Text(
                hm['description']?.toString() ?? '',
                style: TextStyle(color: sl.text2, fontSize: 10.5, height: 1.4))),
              const SizedBox(width: 8),
              // Column 3: CORRECTIVE ACTION
              Expanded(flex: 3, child: Text(
                hm['correctiveAction']?.toString() ?? '',
                style: TextStyle(color: sl.text1, fontSize: 10.5,
                  fontWeight: FontWeight.w500, height: 1.4))),
            ]),
          );
        }),
      ]));
  }

  Widget _sevPill(String sev, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      border: Border.all(color: color, width: 1),
      borderRadius: BorderRadius.circular(4)),
    child: Text(sev,
      style: TextStyle(color: color, fontSize: 8,
          fontWeight: FontWeight.w800)));

  Color _sevColor(String sev) {
    switch (sev.toUpperCase()) {
      case 'CRITICAL': return AppColors.crit;
      case 'HIGH':     return AppColors.red;
      case 'MEDIUM':   return AppColors.cyan;
      case 'LOW':      return AppColors.green;
      default:         return AppColors.amber;
    }
  }

  /// Background color for hazard type badge
  Color _typeColor(String type) {
    switch (type.toLowerCase()) {
      case 'line of fire': return const Color(0xFFFFE0E0); // soft red
      case 'unsafe act':   return const Color(0xFFFFF3E0); // soft orange
      case 'unsafe condition': return const Color(0xFFE3F2FD); // soft blue
      default: return const Color(0xFFF3E5F5); // soft purple
    }
  }

  /// Text color for hazard type badge
  Color _typeTextColor(String type) {
    switch (type.toLowerCase()) {
      case 'line of fire': return const Color(0xFFC62828); // dark red
      case 'unsafe act':   return const Color(0xFFE65100); // dark orange
      case 'unsafe condition': return const Color(0xFF1565C0); // dark blue
      default: return const Color(0xFF6A1B9A); // dark purple
    }
  }

  // ✅ NEW: Hazard Map Legend — horizontally scrollable numbered chips
  // that correlate to bounding boxes on the image. Tapping a chip
  // triggers _onBboxTap which highlights the matching table row.
  Widget _hazardLegendStrip(List hazards, SL sl) {
    final cardBg = sl.isDark ? const Color(0xFF252840) : Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sl.border.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Row(children: [
          const Icon(Icons.my_location_rounded,
              size: 12, color: AppColors.accent),
          const SizedBox(width: 5),
          Text('HAZARD MAP — TAP A CHIP OR BOX TO LOCATE',
            style: TextStyle(color: sl.text4, fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        ]),
        const SizedBox(height: 7),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: hazards.asMap().entries.map((e) {
              final i     = e.key;
              final h     = Map<String, dynamic>.from(e.value as Map);
              final sev   = (h['severity'] ?? 'MEDIUM').toString();
              final color = _sevColor(sev);
              final name  = h['name']?.toString() ?? 'Hazard';
              final isHighlighted = _highlightedRow == i;
              return GestureDetector(
                onTap: () => _onBboxTap(i),
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.fromLTRB(5, 4, 8, 4),
                  decoration: BoxDecoration(
                    color: isHighlighted
                        ? color.withOpacity(0.18)
                        : color.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: color,
                        width: isHighlighted ? 1.5 : 1),
                  ),
                  child: Row(children: [
                    Container(
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                          color: color, shape: BoxShape.circle),
                      child: Center(child: Text('${i+1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800))),
                    ),
                    const SizedBox(width: 7),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                            color: sl.text1, fontSize: 10.5,
                            fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                          color: color.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: color)),
                      child: Text(
                        sev.substring(0, sev.length > 4 ? 4 : sev.length),
                        style: TextStyle(
                            color: color, fontSize: 8,
                            fontWeight: FontWeight.w800)),
                    ),
                  ]),
                ),
              );
            }).toList(),
          ),
        ),
      ]));
  }

  Widget _infoBox(SL sl) {
    final cardBg = sl.isDark ? const Color(0xFF252840) : Colors.white;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border.all(color: AppColors.accent.withOpacity(0.35)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(sl.isDark ? 0.15 : 0.04),
          blurRadius: 6, offset: const Offset(0, 2))]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Row(children: [
          const Icon(Icons.info_outline_rounded,
              size: 14, color: AppColors.accent),
          const SizedBox(width: 6),
          Text('How AI Hazard Scan works',
            style: TextStyle(color: sl.text1, fontSize: 12,
                fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        _infoRow('1.', 'Capture: take a workplace photo', sl),
        _infoRow('2.', 'AI Scan: Gemini detects all hazards', sl),
        _infoRow('3.', 'Review: see all hazards & regulations', sl),
        _infoRow('4.', 'Save: stores to device + Google Sheets', sl),
        _infoRow('5.', 'Mitigate: add action per hazard & close', sl),
      ]));
  }

  Widget _infoRow(String icon, String text, SL sl) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(children: [
      Text(icon, style: const TextStyle(fontSize: 12)),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(
          color: sl.text2, fontSize: 11, height: 1.4))),
    ]));

  // ── GPS Location Card ──────────────────────────────────────
  Widget _locationCard(SL sl) {
    if (_capturedLocation == null || !_capturedLocation!.isValid) {
      return const SizedBox.shrink();
    }

    final loc = _capturedLocation!;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.location_on, color: AppColors.accent, size: 18),
              const SizedBox(width: 8),
              Text('GPS Location', style: TextStyle(
                color: sl.text1,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              )),
              const Spacer(),
              // Edit button
              GestureDetector(
                onTap: _editLocation,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.edit, size: 14, color: AppColors.accent),
                      const SizedBox(width: 4),
                      const Text('Edit', style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      )),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // GPS Coordinates
          if (loc.latitude != null && loc.longitude != null) ...[
            _locationRow(Icons.gps_fixed,
              '${loc.latitude!.toStringAsFixed(6)}, ${loc.longitude!.toStringAsFixed(6)}', sl),
            if (loc.accuracy != null)
              _locationRow(Icons.my_location,
                'Accuracy: ±${loc.accuracy!.toStringAsFixed(1)}m', sl),
          ],

          // Address
          if (loc.address != null && loc.address!.isNotEmpty) ...[
            const SizedBox(height: 4),
            _locationRow(Icons.place, loc.address!, sl),
          ],

          // Timestamp
          const SizedBox(height: 4),
          _locationRow(Icons.access_time,
            'Captured: ${_formatLocationTimestamp(loc.timestamp)}', sl),

          // Google Maps link
          if (loc.latitude != null && loc.longitude != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _openInMaps(loc.latitude!, loc.longitude!),
              child: Row(
                children: [
                  const Icon(Icons.map, size: 14, color: AppColors.accent),
                  const SizedBox(width: 6),
                  const Text('View on Google Maps',
                    style: TextStyle(color: AppColors.accent, fontSize: 12)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _locationRow(IconData icon, String text, SL sl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: sl.text3),
          const SizedBox(width: 8),
          Expanded(child: Text(text,
            style: TextStyle(color: sl.text2, fontSize: 11.5))),
        ],
      ),
    );
  }

  String _formatLocationTimestamp(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _editLocation() {
    final latCtrl = TextEditingController(
      text: _capturedLocation?.latitude?.toString() ?? '',
    );
    final lonCtrl = TextEditingController(
      text: _capturedLocation?.longitude?.toString() ?? '',
    );
    final addrCtrl = TextEditingController(
      text: _capturedLocation?.address ?? '',
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latCtrl,
              decoration: const InputDecoration(
                labelText: 'Latitude',
                hintText: 'e.g., 23.456789',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: lonCtrl,
              decoration: const InputDecoration(
                labelText: 'Longitude',
                hintText: 'e.g., 78.123456',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: addrCtrl,
              decoration: const InputDecoration(
                labelText: 'Address (optional)',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final lat = double.tryParse(latCtrl.text);
              final lon = double.tryParse(lonCtrl.text);
              if (lat != null && lon != null) {
                setState(() {
                  _capturedLocation = LocationData(
                    latitude: lat,
                    longitude: lon,
                    address: addrCtrl.text.isEmpty ? null : addrCtrl.text,
                    accuracy: _capturedLocation?.accuracy,
                    timestamp: _capturedLocation?.timestamp ?? DateTime.now(),
                  );
                  _locationController.text = GeoService.getDisplayAddress(_capturedLocation!);
                });
                _snack('✅ Location updated', AppColors.green);
              } else {
                _snack('⚠️ Invalid coordinates', AppColors.red);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _openInMaps(double lat, double lon) async {
    final url = Uri.parse(GeoService.getGoogleMapsUrl(lat, lon));
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}

