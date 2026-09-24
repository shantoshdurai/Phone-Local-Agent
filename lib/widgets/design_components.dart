import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

// ── Sparkle (auto_awesome) — 4-pointed star matching design icons.jsx ────
class SparkleIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const SparkleIcon({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SparklePainter(color ?? AppTheme.ink),
    );
  }
}

class _SparklePainter extends CustomPainter {
  final Color color;
  _SparklePainter(this.color);

  Path _star(double cx, double cy, double r, {double inner = 0.45}) {
    final p = Path();
    final ri = r * inner;
    p.moveTo(cx, cy - r);
    p.lineTo(cx + ri, cy - ri);
    p.lineTo(cx + r, cy);
    p.lineTo(cx + ri, cy + ri);
    p.lineTo(cx, cy + r);
    p.lineTo(cx - ri, cy + ri);
    p.lineTo(cx - r, cy);
    p.lineTo(cx - ri, cy - ri);
    p.close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final paint = Paint()..color = color;
    canvas.drawPath(_star(12 * s, 11 * s, 7.5 * s, inner: 0.38), paint);
    final small = Paint()..color = color.withValues(alpha: 0.9);
    canvas.drawPath(_star(18.5 * s, 17 * s, 3.2 * s, inner: 0.38), small);
  }

  @override
  bool shouldRepaint(covariant _SparklePainter old) => old.color != color;
}

// ── Brand mark — square with rounded corners + sparkle in center ─────────
class BrandMark extends StatelessWidget {
  final double size;
  final double iconSize;
  final double radius;
  final Color? background;
  final Color? borderColor;
  final Widget? child;

  const BrandMark({
    super.key,
    this.size = 44,
    this.iconSize = 22,
    this.radius = 12,
    this.background,
    this.borderColor,
    this.child,
  });

  const BrandMark.large({super.key})
      : size = 64,
        iconSize = 28,
        radius = 16,
        background = null,
        borderColor = null,
        child = null;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? AppTheme.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? AppTheme.border),
      ),
      alignment: Alignment.center,
      child: child ?? SparkleIcon(size: iconSize),
    );
  }
}

// ── Eyebrow text (mono, uppercase, tracked) ──────────────────────────────
class Eyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  final double fontSize;
  final double letterSpacing;
  const Eyebrow(this.text, {super.key, this.color, this.fontSize = 10, this.letterSpacing = 1.6});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.jetBrainsMono(
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        letterSpacing: letterSpacing,
        color: color ?? AppTheme.muted,
      ),
    );
  }
}

// ── Primary button (ink background) ───────────────────────────────────────
class PrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final Widget? leading;
  final bool isLoading;
  final bool disabled;
  final Color? background;
  final Color? foreground;
  const PrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.leading,
    this.isLoading = false,
    this.disabled = false,
    this.background,
    this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading && !disabled;
    final bg = background ?? AppTheme.primary;
    final fg = foreground ?? AppTheme.onPrimary;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: enabled ? bg : AppTheme.surface3,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onPressed : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isLoading)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.8, color: fg),
                  )
                else ...[
                  if (leading != null) ...[leading!, const SizedBox(width: 8)]
                  else if (icon != null) ...[Icon(icon, size: 14, color: enabled ? fg : AppTheme.muted), const SizedBox(width: 8)],
                  Text(
                    label.toUpperCase(),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.4,
                      color: enabled ? fg : AppTheme.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Secondary (outlined) button ──────────────────────────────────────────
class SecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  const SecondaryButton({super.key, required this.onPressed, required this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppTheme.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            child: Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.4,
                color: AppTheme.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Pill / badge ──────────────────────────────────────────────────────────
enum PillStyle { solid, surface, outline, success }

class Pill extends StatelessWidget {
  final String text;
  final PillStyle style;
  final double fontSize;
  const Pill(this.text, {super.key, this.style = PillStyle.surface, this.fontSize = 9});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    Border? border;
    switch (style) {
      case PillStyle.solid:
        bg = AppTheme.primary;
        fg = AppTheme.onPrimary;
        break;
      case PillStyle.outline:
        bg = Colors.transparent;
        fg = AppTheme.ink2;
        border = Border.all(color: AppTheme.border2);
        break;
      case PillStyle.success:
        bg = AppTheme.success.withValues(alpha: 0.14);
        fg = AppTheme.successInk;
        break;
      case PillStyle.surface:
        bg = AppTheme.surface2;
        fg = AppTheme.ink2;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: border,
      ),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: fg,
        ),
      ),
    );
  }
}

// ── Card surface ──────────────────────────────────────────────────────────
class DesignCard extends StatelessWidget {
  final Widget child;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  const DesignCard({
    super.key,
    required this.child,
    this.selected = false,
    this.padding = const EdgeInsets.all(20),
    this.radius = 16,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: selected ? AppTheme.surface2 : AppTheme.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: selected ? AppTheme.primary : AppTheme.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}

// ── Custom top app bar (replaces default Material AppBar) ────────────────
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  final Widget? leading;
  final Widget? trailing;
  final Widget title;
  final bool divider;
  const AppHeader({
    super.key,
    this.leading,
    this.trailing,
    required this.title,
    this.divider = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null,
      ),
      child: Row(
        children: [
          SizedBox(width: 36, height: 36, child: Center(child: leading ?? const SizedBox.shrink())),
          Expanded(child: Center(child: title)),
          SizedBox(width: 36, height: 36, child: Center(child: trailing ?? const SizedBox.shrink())),
        ],
      ),
    );
  }
}

class HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onPressed;
  const HeaderIconButton({super.key, required this.icon, this.size = 20, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Icon(icon, size: size, color: AppTheme.ink2),
        ),
      ),
    );
  }
}

// ── Toggle switch (iOS-ish, monochrome) ──────────────────────────────────
class DesignSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const DesignSwitch({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 38,
        height: 22,
        decoration: BoxDecoration(
          color: value ? AppTheme.primary : AppTheme.border2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 160),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: value ? AppTheme.onPrimary : Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Settings cell ────────────────────────────────────────────────────────
class SettingsCell extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isFirst;
  const SettingsCell({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: GoogleFonts.interTight(fontSize: 14, color: AppTheme.ink, fontWeight: FontWeight.w500)),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: GoogleFonts.interTight(fontSize: 12, color: AppTheme.ink2)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
    final decorated = Container(
      decoration: BoxDecoration(
        border: isFirst ? null : Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: row,
    );
    if (onTap == null) return decorated;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: decorated),
    );
  }
}

class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const SettingsGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: children),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  const SectionHeader(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(24, 22, 24, 8)});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Eyebrow(text),
    );
  }
}

// ── Model chip ────────────────────────────────────────────────────────────
class ModelChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const ModelChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppTheme.muted),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 10.5,
              color: AppTheme.muted,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
