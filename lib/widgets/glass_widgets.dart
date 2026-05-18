import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Three radial blobs + a faint dot grid. Lives behind the scaffold body —
/// every screen that uses it should put it inside a `Stack` and place the
/// actual content after it.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                top: -150,
                right: -100,
                child: _blob(
                  size: 500,
                  color: AppTheme.glassAccent.withValues(alpha: 0.35),
                ),
              ),
              Positioned(
                top: 200,
                left: -200,
                child: _blob(
                  size: 450,
                  color: AppTheme.glassMagenta.withValues(alpha: 0.2),
                ),
              ),
              Positioned(
                bottom: -150,
                right: -100,
                child: _blob(
                  size: 400,
                  color: AppTheme.glassCyan.withValues(alpha: 0.15),
                ),
              ),
              Opacity(
                opacity: 0.08,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _DotGridPainter(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _blob({required double size, required Color color}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, Colors.transparent],
          stops: const [0.0, 0.65],
        ),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    const spacing = 20.0;
    const radius = 0.6;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// Glassmorphism card — translucent fill, backdrop blur, soft inner gradient.
/// Designed to sit on top of the aurora background; on a plain dark surface
/// it still reads correctly because of the gradient.
class GlassCard extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Border? border;
  final List<BoxShadow>? shadows;

  const GlassCard({
    super.key,
    required this.child,
    this.blur = 30.0,
    this.opacity = 0.05,
    this.borderRadius,
    this.padding,
    this.margin,
    this.border,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(24);
    final fillColor = Colors.white.withValues(alpha: opacity.clamp(0.01, 0.1));
    final borderColor = AppTheme.glassBorder2.withValues(alpha: 0.12);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadows ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 32,
                offset: const Offset(0, 12),
                spreadRadius: -8,
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding ?? const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: radius,
              border: border ?? Border.all(color: borderColor, width: 0.8),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.08),
                  Colors.white.withValues(alpha: 0.02),
                ],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Full-width gradient button used as the primary CTA on intro / step screens.
/// Shows a spinner when [isLoading] is true.
class GradientButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final bool isLoading;
  final double height;

  const GradientButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.isLoading = false,
    this.height = 60,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;
    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: Container(
        width: double.infinity,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            colors: [AppTheme.glassAccent, AppTheme.glassAccent2],
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppTheme.glassAccent.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: enabled ? onPressed : null,
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : Text(
                      label,
                      style: AppTextStyles.mono.copyWith(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary outlined / ghost button. Used for "Skip", "Continue anyway", etc.
class GhostButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final double height;

  const GhostButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: AppTheme.glassBorder),
            ),
            child: Center(
              child: Text(
                label,
                style: AppTextStyles.bodyStrong.copyWith(
                  color: AppTheme.glassInk2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small "STEP n/total" indicator displayed at the top of multi-step flows.
class StepIndicator extends StatelessWidget {
  final int step;
  final int total;
  const StepIndicator({super.key, required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    return Text(
      'STEP $step/$total',
      style: AppTextStyles.mono.copyWith(
        color: AppTheme.glassMuted,
        letterSpacing: 2.0,
        fontSize: 10,
      ),
    );
  }
}
