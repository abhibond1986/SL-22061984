import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show AppColors, SL;
import 'safe_backdrop_filter.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blur;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16,
    this.blur = 12,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SafeBackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding ?? const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: sl.glassColor,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: borderColor ?? sl.glassBorder,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(sl.isDark ? 0.2 : 0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;
  final double blur;

  const GlassContainer({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius = 12,
    this.blur = 8,
  });

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SafeBackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: sl.glassColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: sl.glassBorder, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }
}
