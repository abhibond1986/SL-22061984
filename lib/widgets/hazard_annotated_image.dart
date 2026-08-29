// lib/widgets/hazard_annotated_image.dart
// Shows the FULL image at its natural aspect ratio with hazard bounding boxes.
// No zoom, no crop — the entire uploaded image stays visible.
//
// Each hazard's `bbox` is expected as [yMin, xMin, yMax, xMax] normalized 0–1000
// (Gemini Vision format) OR as [x, y, w, h] normalized 0–1.
//
// A hazard may also carry `lofZone`, the LINE OF FIRE: the path from an energy
// source to the person standing in it. That is drawn as a directional corridor
// and arrow (see _LineOfFirePainter), with geometry resolved by the shared
// services/line_of_fire.dart so the screen and the exported PDF cannot disagree.

// No additional imports needed — LinearGradient comes from material.dart
import 'dart:math' as math;
import 'dart:ui' as ui show Gradient;

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

        // Respect a bounded height from the caller. Width-driven sizing alone
        // makes a portrait photo taller than its slot — the widget used to
        // overflow instead of letterboxing, so a caller could only ever place it
        // somewhere with unlimited vertical room. Capping here and centring the
        // narrower image keeps the annotation geometry correct, because the
        // overlay is positioned on the SAME rect the photo is drawn in.
        if (constraints.hasBoundedHeight &&
            constraints.maxHeight.isFinite &&
            imageRenderH > constraints.maxHeight) {
          imageRenderH = constraints.maxHeight;
          imageRenderW = imageRenderH * aspect;
          offsetX = (containerW - imageRenderW) / 2;
        }

        return SizedBox(
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
      },
    );
  }
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

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Line-of-fire paths, rendered BELOW the bounding boxes so a box
            // outline is never hidden by the corridor shading.
            //
            // Drawn for ANY hazard that resolves to a usable path, not only
            // those the model happened to type 'Line of Fire': a worker under a
            // suspended load is in the line of fire whichever label the row got.
            ...hazards.asMap().entries.map((entry) {
              final hazard = entry.value;
              if (hazard is! Map) return const SizedBox.shrink();
              final lof = LineOfFireGeometry.parse(hazard);
              if (lof == null) return const SizedBox.shrink();
              return Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _LineOfFirePainter(
                      lof: lof,
                      index: entry.key,
                    ),
                  ),
                ),
              );
            }),
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
  static const Color _warm  = Color(0xFFFF7043); // corridor gradient far end
  static const Color _halo  = Color(0xE6FFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 8 || size.height < 8) return;
    final plan = LineOfFireGeometry.plan(lof, size.width, size.height);

    // No usable direction: the model put the source and the person on top of
    // each other. Mark the spot honestly rather than drawing a zero-length
    // arrow that would point at nothing in particular.
    if (plan.degenerate) {
      _drawExposureRing(canvas, Offset(plan.personX, plan.personY), 14);
      _drawLabel(canvas, size, Offset(plan.personX, plan.personY + 22),
          '⚠ LINE OF FIRE ${index + 1}');
      return;
    }

    final corridor = Path();
    corridor.moveTo(plan.corridor[0].x, plan.corridor[0].y);
    for (final p in plan.corridor.skip(1)) {
      corridor.lineTo(p.x, p.y);
    }
    corridor.close();

    // ── Corridor fill: strongest at the person, where the energy arrives ──
    canvas.drawPath(
      corridor,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(plan.sourceX, plan.sourceY),
          Offset(plan.personX, plan.personY),
          const [Color(0x1AFF7043), Color(0x4DE53935)],
        ),
    );

    // ── Hatching, clipped to the corridor: reads as "keep out" ──
    canvas.save();
    canvas.clipPath(corridor);
    final hatch = Paint()
      ..color = const Color(0x33E53935)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final bounds = corridor.getBounds();
    const spacing = 9.0;
    for (double d = 0; d < bounds.width + bounds.height; d += spacing) {
      canvas.drawLine(
        Offset(bounds.left + d, bounds.top),
        Offset(bounds.left + d - bounds.height, bounds.bottom),
        hatch,
      );
    }
    canvas.restore();

    // ── Corridor edges, haloed so they read on any background ──
    canvas.drawPath(
      corridor,
      Paint()
        ..color = _halo
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4,
    );
    canvas.drawPath(
      corridor,
      Paint()
        ..color = _hot.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // ── The arrow itself, along the centre line ──
    // Stops short of the person so the arrowhead sits beside them rather than
    // covering the very thing the reader is being asked to look at.
    final headLen = (plan.halfWidth * 1.35).clamp(11.0, 30.0);
    final shaftEnd = _along(plan, plan.length - headLen * 0.9);
    final shaftStart = _along(plan, math.min(plan.length * 0.12, 14.0));

    canvas.drawLine(shaftStart, shaftEnd,
        Paint()..color = _halo..strokeWidth = 6.0..strokeCap = StrokeCap.round);
    canvas.drawLine(shaftStart, shaftEnd,
        Paint()..color = _hot..strokeWidth = 3.0..strokeCap = StrokeCap.round);

    _drawArrowHead(canvas, plan, headLen);

    // ── Source burst: where the energy comes from ──
    _drawSourceBurst(canvas, Offset(plan.sourceX, plan.sourceY),
        (plan.halfWidth * 0.55).clamp(7.0, 15.0));

    // ── The exposed person ──
    _drawExposureRing(canvas, Offset(plan.personX, plan.personY),
        (plan.halfWidth * 0.8).clamp(11.0, 24.0));

    // ── Label, placed off to the side of the midpoint so it never sits on top
    //    of the arrowhead or the person.
    final mid = _along(plan, plan.length * 0.5);
    final nx = -math.sin(plan.angle);
    final ny = math.cos(plan.angle);
    final labelAnchor = Offset(
      mid.dx + nx * (plan.halfWidth + 12),
      mid.dy + ny * (plan.halfWidth + 12),
    );
    final exposure = lof.exposure.isEmpty ? '' : ' · ${lof.exposure}';
    _drawLabel(canvas, size, labelAnchor,
        '⚠ LINE OF FIRE ${index + 1}$exposure');
  }

  /// A point [distance] pixels along the source→person centre line.
  Offset _along(LofPlan plan, double distance) {
    final t = plan.length == 0 ? 0.0 : (distance / plan.length).clamp(0.0, 1.0);
    return Offset(
      plan.sourceX + (plan.personX - plan.sourceX) * t,
      plan.sourceY + (plan.personY - plan.sourceY) * t,
    );
  }

  void _drawArrowHead(Canvas canvas, LofPlan plan, double headLen) {
    final tip = _along(plan, plan.length - headLen * 0.15);
    final back = _along(plan, plan.length - headLen * 1.15);
    final nx = -math.sin(plan.angle);
    final ny = math.cos(plan.angle);
    final halfBase = headLen * 0.58;

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

  /// Short radiating strokes at the energy source — the visual shorthand for
  /// "this is where it comes from", distinguishable from the ring on the person.
  void _drawSourceBurst(Canvas canvas, Offset c, double r) {
    final halo = Paint()
      ..color = _halo
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round;
    final ink = Paint()
      ..color = _warm
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final p1 = Offset(c.dx + math.cos(a) * r * 0.45,
          c.dy + math.sin(a) * r * 0.45);
      final p2 = Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
      canvas.drawLine(p1, p2, halo);
      canvas.drawLine(p1, p2, ink);
    }
    canvas.drawCircle(c, r * 0.3, Paint()..color = _halo);
    canvas.drawCircle(c, r * 0.22, Paint()..color = _warm);
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

  /// Label on an opaque plate. Kept fully inside [size] — a caption clipped at
  /// the image edge is how "LINE OF FIRE" becomes "LINE OF FI".
  void _drawLabel(Canvas canvas, Size size, Offset anchor, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFFB3261E),
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(60.0, size.width - 16));

    var left = anchor.dx - tp.width / 2;
    var top = anchor.dy - tp.height / 2;
    left = left.clamp(4.0, math.max(4.0, size.width - tp.width - 4));
    top = top.clamp(4.0, math.max(4.0, size.height - tp.height - 4));

    final plate = RRect.fromRectAndRadius(
      Rect.fromLTWH(left - 5, top - 3, tp.width + 10, tp.height + 6),
      const Radius.circular(4),
    );
    canvas.drawRRect(plate, Paint()..color = const Color(0xF2FFFFFF));
    canvas.drawRRect(plate, Paint()
      ..color = _hot.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0);
    tp.paint(canvas, Offset(left, top));
  }

  @override
  bool shouldRepaint(covariant _LineOfFirePainter old) =>
      old.index != index ||
      old.lof.sourceX != lof.sourceX ||
      old.lof.sourceY != lof.sourceY ||
      old.lof.personX != lof.personX ||
      old.lof.personY != lof.personY ||
      old.lof.width != lof.width ||
      old.lof.exposure != lof.exposure;
}
