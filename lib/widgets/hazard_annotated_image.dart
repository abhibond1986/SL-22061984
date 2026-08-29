// lib/widgets/hazard_annotated_image.dart
// Shows the FULL image at its natural aspect ratio with hazard bounding boxes.
// No zoom, no crop — the entire uploaded image stays visible.
//
// Each hazard's `bbox` is expected as [yMin, xMin, yMax, xMax] normalized 0–1000
// (Gemini Vision format) OR as [x, y, w, h] normalized 0–1.
//
// A hazard may also carry `lofZone`, the LINE OF FIRE: the path from a named
// energy source to the person standing in it. Exactly ONE is drawn per image —
// the most severe one with a real person in it — as an arrow with a dot at the
// source and a ring on the person (see _LineOfFirePainter). When the source is
// real but nobody is in the photograph, a dashed exposure ZONE is drawn instead
// of an arrow. Its wording sits in a legend UNDER the picture rather than on it.
// Geometry and captions both come from the shared services/line_of_fire.dart so
// the screen and the exported PDF cannot disagree.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../services/line_of_fire.dart';

class HazardAnnotatedImage extends StatefulWidget {
  final Uint8List imageBytes;
  final List hazards;
  final void Function(int index)? onHazardTap;

  const HazardAnnotatedImage({
    super.key,
    required this.imageBytes,
    required this.hazards,
    this.onHazardTap,
  });

  @override
  State<HazardAnnotatedImage> createState() => _HazardAnnotatedImageState();
}

class _HazardAnnotatedImageState extends State<HazardAnnotatedImage> {
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  @override
  void didUpdateWidget(HazardAnnotatedImage old) {
    super.didUpdateWidget(old);
    if (old.imageBytes != widget.imageBytes) _resolveImageSize();
  }

  void _resolveImageSize() {
    final img = MemoryImage(widget.imageBytes);
    final stream = img.resolve(const ImageConfiguration());
    stream.addListener(
      ImageStreamListener(
        (info, _) {
          if (mounted) {
            setState(() {
              _imageSize = Size(
                info.image.width.toDouble(),
                info.image.height.toDouble(),
              );
            });
          }
        },
        onError: (e, _) {
          // Fallback if image resolution fails (e.g., on web)
          if (mounted) {
            setState(() {
              _imageSize = const Size(1024, 768); // assume 4:3
            });
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerW = constraints.maxWidth;

        // Calculate actual rendered image dimensions (BoxFit.contain)
        double imageRenderW = containerW;
        double imageRenderH;
        double offsetX = 0;
        double offsetY = 0;

        final aspect =
            (_imageSize != null && _imageSize!.width > 0 && _imageSize!.height > 0)
                ? _imageSize!.width / _imageSize!.height
                : 4 / 3; // assume 4:3 until the image decodes
        imageRenderH = containerW / aspect;

        // The line-of-fire caption, if there is one. It is rendered UNDER the
        // photograph, and its height comes out of the space available to the
        // photograph — otherwise a caller that gives this widget a bounded height
        // gets an overflow instead of a legend.
        final pick = LineOfFireGeometry.pickOne(widget.hazards);
        final legend =
            pick == null ? '' : LineOfFireGeometry.caption(pick.index, pick.lof);
        final legendH = legend.isEmpty ? 0.0 : _legendHeight;

        // Respect a bounded height from the caller. Width-driven sizing alone
        // makes a portrait photo taller than its slot — the widget used to
        // overflow instead of letterboxing, so a caller could only ever place it
        // somewhere with unlimited vertical room. Capping here and centring the
        // narrower image keeps the annotation geometry correct, because the
        // overlay is positioned on the SAME rect the photo is drawn in.
        if (constraints.hasBoundedHeight &&
            constraints.maxHeight.isFinite &&
            imageRenderH > constraints.maxHeight - legendH) {
          imageRenderH = math.max(1.0, constraints.maxHeight - legendH);
          imageRenderW = imageRenderH * aspect;
          offsetX = (containerW - imageRenderW) / 2;
        }

        final photo = SizedBox(
          width: containerW,
          height: imageRenderH,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // Full image
              Positioned(
                left: offsetX,
                top: offsetY,
                width: imageRenderW,
                height: imageRenderH,
                child: Image.memory(
                  widget.imageBytes,
                  fit: BoxFit.contain,
                ),
              ),
              // Overlay bounding boxes — constrained to image area
              Positioned(
                left: offsetX,
                top: offsetY,
                width: imageRenderW,
                height: imageRenderH,
                child: _BboxOverlay(
                  hazards: widget.hazards,
                  onHazardTap: widget.onHazardTap,
                ),
              ),
            ],
          ),
        );

        if (legend.isEmpty) return photo;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [photo, _legendBar(legend)],
        );
      },
    );
  }

  /// Reserved height for the legend strip. Fixed rather than measured: the
  /// caption is one short line by construction (see LineOfFireGeometry.caption)
  /// and the photograph's height has to be known before the legend is laid out.
  static const double _legendHeight = 22;

  /// The caption that used to be stamped across the photograph. Down here it can
  /// be read, and the number ties it to the bounding box above.
  Widget _legendBar(String text) => Container(
        height: _legendHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        // Opaque, not a translucent red wash: this strip can sit on the light or
        // the dark surface, and a translucent fill would put dark-red text on a
        // near-black background in dark mode.
        color: const Color(0xFFFDECEA),
        child: Row(children: [
          Container(
            width: 12,
            height: 3,
            decoration: BoxDecoration(
              color: const Color(0xFFE53935),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                // Not a theme colour: the strip carries its own opaque pale-red
                // fill in both themes, so the pairing is fixed. #B3261E on
                // #FDECEA is 5.7:1 — above the 4.5:1 AA floor.
                color: Color(0xFFB3261E),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ]),
      );
}

class _BboxOverlay extends StatelessWidget {
  final List hazards;
  final void Function(int index)? onHazardTap;

  const _BboxOverlay({required this.hazards, this.onHazardTap});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final pick = LineOfFireGeometry.pickOne(hazards);

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // THE line of fire — exactly one, rendered below the bounding boxes
            // so a box outline is never hidden by it.
            //
            // One, not one per hazard: three arrows across a wide shop-floor
            // photograph is a tangle nobody reads. The others keep their
            // numbered boxes and their table rows.
            if (pick != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _LineOfFirePainter(
                      lof: pick.lof,
                      index: pick.index,
                    ),
                  ),
                ),
              ),
            // ✅ Bbox overlays
            ...hazards.asMap().entries.map((entry) {
            final i = entry.key;
            final hazard = Map<String, dynamic>.from(entry.value as Map);
            final bbox = hazard['bbox'];
            if (bbox == null) return const SizedBox.shrink();

            // ✅ v17: Handle bbox as Map {x, y, w, h} OR List [x1, y1, x2, y2]
            final List<num> box;
            if (bbox is Map) {
              // Gemini prompt asks for {x, y, w, h} format
              final x = num.tryParse(bbox['x']?.toString() ?? '') ?? 0;
              final y = num.tryParse(bbox['y']?.toString() ?? '') ?? 0;
              final bw = num.tryParse(bbox['w']?.toString() ?? bbox['width']?.toString() ?? '') ?? 0;
              final bh = num.tryParse(bbox['h']?.toString() ?? bbox['height']?.toString() ?? '') ?? 0;
              box = [x, y, bw, bh];
            } else if (bbox is List) {
              box = bbox.map((e) => (e is num) ? e : num.tryParse(e.toString()) ?? 0).toList();
            } else {
              return const SizedBox.shrink();
            }

            if (box.length < 4) return const SizedBox.shrink();

            // Determine format: Gemini returns [yMin, xMin, yMax, xMax] in 0-1000 range
            // OR some APIs return [x, y, width, height] in 0-1 range
            double left, top, right, bottom;

            if (bbox is Map || box.every((v) => v <= 1.1)) {
              // Normalized 0-1 format: [x, y, w, h] (from Map or List)
              left   = box[0].toDouble() * w;
              top    = box[1].toDouble() * h;
              right  = (box[0].toDouble() + box[2].toDouble()) * w;
              bottom = (box[1].toDouble() + box[3].toDouble()) * h;
            } else {
              // Gemini 0-1000 format: [yMin, xMin, yMax, xMax]
              top    = (box[0].toDouble() / 1000) * h;
              left   = (box[1].toDouble() / 1000) * w;
              bottom = (box[2].toDouble() / 1000) * h;
              right  = (box[3].toDouble() / 1000) * w;
            }

            // Clamp to valid range
            left   = left.clamp(0, w);
            top    = top.clamp(0, h);
            right  = right.clamp(0, w);
            bottom = bottom.clamp(0, h);

            final double boxWidth  = (right - left).clamp(20.0, w).toDouble();
            final double boxHeight = (bottom - top).clamp(20.0, h).toDouble();

            final severity = (hazard['severity']?.toString() ?? 'MEDIUM').toUpperCase();
            final color = _sevColor(severity);
            final name = hazard['name']?.toString() ?? 'Hazard ${i + 1}';

            return Positioned(
              left: left,
              top: top,
              width: boxWidth,
              height: boxHeight,
              child: GestureDetector(
                onTap: () => onHazardTap?.call(i),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: color, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                    color: color.withOpacity(0.08),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Label at top of box
                      Positioned(
                        top: -1,
                        left: -1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              bottomRight: Radius.circular(6),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 14,
                                height: 14,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      color: color,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                    maxWidth: boxWidth * 0.7),
                                child: Text(
                                  name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
          ],
        );
      },
    );
  }

  Color _sevColor(String sev) {
    switch (sev.toUpperCase()) {
      case 'CRITICAL': return const Color(0xFFDC2626);
      case 'HIGH':     return const Color(0xFFEF4444);
      case 'MEDIUM':   return const Color(0xFFF59E0B);
      case 'LOW':      return const Color(0xFF10B981);
      default:         return const Color(0xFFF59E0B);
    }
  }
}

/// Draws one hazard's LINE OF FIRE: a tapered danger corridor running from the
/// energy source to the person standing in its path, with an arrowhead at the
/// person end.
///
/// WHY A DIRECTION AND NOT A BOX
/// -----------------------------
/// This replaces a painter that read the path's two endpoints as a rectangle's
/// corners. That was wrong twice over. It drew a region where the concept is
/// about a direction, and — because `Rect.fromLTRB` produces a negative width
/// when right < left — it drew NOTHING at all whenever the exposed person stood
/// above or to the left of the energy source, which is about half of real
/// photographs. A silently missing line of fire is the worst possible failure
/// here: the reader sees a clean image and concludes nobody is exposed.
///
/// Everything is drawn with a white halo underneath. A shop-floor photograph can
/// be any colour, and a red arrow over rust or a red ladle is invisible.
class _LineOfFirePainter extends CustomPainter {
  _LineOfFirePainter({required this.lof, required this.index});

  final LineOfFire lof;

  /// Hazard's position in the list, so the arrow can be tied to the numbered
  /// bounding box and table row rather than floating unexplained.
  final int index;

  static const Color _hot   = Color(0xFFE53935); // energy / danger
  static const Color _halo  = Color(0xE6FFFFFF);

  /// Draws ONE arrow from the energy source to the exposed person, a dot at the
  /// source, a ring on the person, and a short caption. Nothing else.
  ///
  /// WHY SO PLAIN: the first version shaded a tapering, hatched corridor between
  /// the two ends, with radiating rays at the source. On a busy shop-floor
  /// photograph that read as damage to the image rather than as information —
  /// and the hatching obscured the very equipment the reader was being told to
  /// look at. A safety officer needs to answer two questions in one glance:
  /// what could hit someone, and who. An arrow answers both. It also survives
  /// the two conditions this drawing actually has to live through: a thumbnail
  /// in a list, and a monochrome print of the PDF.
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 8 || size.height < 8) return;
    final plan = LineOfFireGeometry.plan(lof, size.width, size.height);

    // Nobody is actually in the picture. Mark the ZONE a person would be struck
    // in — dashed, because dashes read as "notional" everywhere from drawings to
    // road markings — and draw no arrow at all. An arrow asserts a person; this
    // says "if anyone stands here". See LineOfFire.personVisible for the report
    // that made this necessary.
    if (!lof.personVisible) {
      _drawExposureZone(canvas, size, plan);
      return;
    }

    // No usable direction: the model put the source and the person on top of
    // each other. Mark the spot honestly rather than drawing a zero-length
    // arrow that would point at nothing in particular.
    if (plan.degenerate) {
      _drawExposureRing(canvas, Offset(plan.personX, plan.personY), 14);
      return;
    }

    final source = Offset(plan.sourceX, plan.sourceY);
    final person = Offset(plan.personX, plan.personY);

    // Arrowhead scaled to the arrow, not to the corridor width, and capped so a
    // short exposure does not become a head with no shaft.
    final headLen = (plan.length * 0.22).clamp(9.0, 22.0);
    final ringR = (plan.halfWidth * 0.8).clamp(11.0, 24.0);

    // Both ends are pulled in: the tail clears the source dot, and the head
    // stops at the ring rather than covering the person — their posture and PPE
    // are frequently the actual finding.
    final startD = math.min(6.0, plan.length * 0.15);
    final endD =
        math.max(startD + 1.0, plan.length - ringR - headLen * 0.85);
    final shaftStart = _along(plan, startD);
    final shaftEnd = _along(plan, endD);

    canvas.drawLine(shaftStart, shaftEnd,
        Paint()..color = _halo..strokeWidth = 6.5..strokeCap = StrokeCap.round);
    canvas.drawLine(shaftStart, shaftEnd,
        Paint()..color = _hot..strokeWidth = 3.2..strokeCap = StrokeCap.round);

    _drawArrowHead(canvas, plan, headLen, ringR);
    _drawSourceDot(canvas, source);
    _drawExposureRing(canvas, person, ringR);

    // NO caption is drawn here. It used to be an opaque plate at the arrow's
    // midpoint; with several paths on one photograph the plates overlapped each
    // other and the picture. The wording now lives in the legend under the
    // image, tied to this arrow by the hazard number on its bounding box.
  }

  /// The area a person would be struck in, when no person is in the photograph.
  ///
  /// A dashed square centred on where the model said someone would be, plus a
  /// dashed link back to the source so the reader can see WHERE it would come
  /// from. Nothing solid, nothing filled: every solid mark in this overlay means
  /// "this is here", and the whole point of the zone is that it is not.
  void _drawExposureZone(Canvas canvas, Size size, LofPlan plan) {
    final half = (plan.halfWidth * 0.9).clamp(13.0, 46.0);
    final centre = Offset(plan.personX, plan.personY);
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: half * 2, height: half * 2),
      const Radius.circular(5),
    );

    // Halo first, as one solid pass underneath: without it a dashed red outline
    // disappears completely over rust or red machinery.
    canvas.drawRRect(rect, Paint()
      ..color = _halo
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0);
    _dashRRect(canvas, rect, Paint()
      ..color = _hot
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2);

    // A short dashed stub toward the source, only when the source is far enough
    // away to be a different place. It carries no arrowhead — direction without
    // a person at the end is exactly the claim being avoided.
    if (plan.length > half * 1.8) {
      final from = _along(plan, math.min(10.0, plan.length * 0.12));
      final to = _along(plan, plan.length - half * 1.35);
      _dashLine(canvas, from, to, Paint()
        ..color = _halo
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round);
      _dashLine(canvas, from, to, Paint()
        ..color = _hot.withOpacity(0.85)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round);
      _drawSourceDot(canvas, Offset(plan.sourceX, plan.sourceY));
    }
  }

  static const double _dashOn = 6.0;
  static const double _dashOff = 4.0;

  void _dashLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final total = (b - a).distance;
    if (total < 1) return;
    final step = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final end = math.min(t + _dashOn, total);
      canvas.drawLine(a + step * t, a + step * end, paint);
      t = end + _dashOff;
    }
  }

  void _dashRRect(Canvas canvas, RRect rrect, Paint paint) {
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var t = 0.0;
      while (t < metric.length) {
        final end = math.min(t + _dashOn, metric.length);
        canvas.drawPath(metric.extractPath(t, end), paint);
        t = end + _dashOff;
      }
    }
  }

  /// A point [distance] pixels along the source→person centre line.
  Offset _along(LofPlan plan, double distance) {
    final t = plan.length == 0 ? 0.0 : (distance / plan.length).clamp(0.0, 1.0);
    return Offset(
      plan.sourceX + (plan.personX - plan.sourceX) * t,
      plan.sourceY + (plan.personY - plan.sourceY) * t,
    );
  }

  void _drawArrowHead(
      Canvas canvas, LofPlan plan, double headLen, double ringR) {
    // The tip stops at the edge of the ring on the person, so the arrow reads as
    // "arriving at them" without drawing over them.
    final tipD = math.max(headLen, plan.length - ringR);
    final tip = _along(plan, tipD);
    final back = _along(plan, tipD - headLen);
    final nx = -math.sin(plan.angle);
    final ny = math.cos(plan.angle);
    final halfBase = headLen * 0.55;

    final head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(back.dx + nx * halfBase, back.dy + ny * halfBase)
      ..lineTo(back.dx - nx * halfBase, back.dy - ny * halfBase)
      ..close();

    canvas.drawPath(head, Paint()
      ..color = _halo
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(head, Paint()..color = _hot);
  }

  /// A small filled dot at the energy source: enough to say "it starts here",
  /// small enough not to compete with the ring on the person, who is the point.
  void _drawSourceDot(Canvas canvas, Offset c) {
    canvas.drawCircle(c, 5.0, Paint()..color = _halo);
    canvas.drawCircle(c, 3.2, Paint()..color = _hot);
  }

  /// Concentric ring marking the person in the path. A ring rather than a filled
  /// disc, so their posture and PPE stay visible underneath — that detail is
  /// often the actual finding.
  void _drawExposureRing(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(c, r, Paint()
      ..color = _halo
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5);
    canvas.drawCircle(c, r, Paint()
      ..color = _hot
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4);
    canvas.drawCircle(c, r * 0.45, Paint()
      ..color = _hot.withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);
  }

  // _drawLabel() was deleted here. It painted the caption on an opaque plate at
  // the arrow's midpoint. On a report with three paths the three plates were each
  // as wide as the photograph, overlapped one another and hid the equipment being
  // described — the caption is now a legend line under the image, built by
  // LineOfFireGeometry.caption() so the screen and the PDF word it identically.

  @override
  bool shouldRepaint(covariant _LineOfFirePainter old) =>
      old.index != index ||
      old.lof.personVisible != lof.personVisible ||
      old.lof.sourceX != lof.sourceX ||
      old.lof.sourceY != lof.sourceY ||
      old.lof.personX != lof.personX ||
      old.lof.personY != lof.personY ||
      old.lof.width != lof.width ||
      old.lof.exposure != lof.exposure ||
      old.lof.source != lof.source;
}
