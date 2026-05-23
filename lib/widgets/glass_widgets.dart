import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// AuroraBackground is now deprecated and returns an empty container.
/// This enforces the stark, minimal aesthetic.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

/// GlassCard renamed internally to MinimalCard concept, but class name kept
/// for compatibility. Provides a stark, flat UI container with a 1px border.
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
    this.blur = 0,
    this.opacity = 0,
    this.borderRadius,
    this.padding,
    this.margin,
    this.border,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(16);

    return Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.glassSurface,
        borderRadius: radius,
        border: border ?? Border.all(color: AppTheme.glassBorder, width: 1.0),
      ),
      child: child,
    );
  }
}

/// A stark, high-contrast flat button. No gradients.
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
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: ElevatedButton(
          onPressed: enabled ? onPressed : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.glassInk,
            foregroundColor: AppTheme.glassBg,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: isLoading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: AppTheme.glassBg,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  label,
                  style: AppTextStyles.mono.copyWith(
                    color: AppTheme.glassBg,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
        ),
      ),
    );
  }
}

/// A minimal outlined button.
class GhostButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final double height;

  const GhostButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.glassInk,
          side: const BorderSide(color: AppTheme.glassBorder, width: 1.0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(
          label,
          style: AppTextStyles.bodyStrong.copyWith(
            color: AppTheme.glassInk,
          ),
        ),
      ),
    );
  }
}

/// Small "STEP n/total" indicator.
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
