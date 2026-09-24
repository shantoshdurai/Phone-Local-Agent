import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../services/report_service.dart';
import '../theme/app_theme.dart';
import 'design_components.dart';

/// Chat bubble — user messages render as a grey rounded pill on the right,
/// agent messages render as plain text under a sparkle icon.
class MessageBubble extends StatefulWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  ChatMessage get message => widget.message;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: widget.message.skipEntrance ? 1.0 : 0.0,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    if (!widget.message.skipEntrance) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: message.isUser ? _userMessage() : _agentMessage(),
        ),
      ),
    );
  }

  Widget _image(String path, {double width = 220}) {
    final file = File(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        file,
        width: width,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: width,
          height: 64,
          color: AppTheme.surface,
          alignment: Alignment.center,
          child: Text('Image unavailable',
              style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _userMessage() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: GestureDetector(
            onLongPress: _copy,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.userBubble,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.imagePath != null)
                      Padding(
                        padding: EdgeInsets.only(bottom: message.text.isEmpty ? 0 : 8),
                        child: _image(message.imagePath!),
                      ),
                    if (message.text.isNotEmpty)
                      Text(
                        message.text,
                        style: GoogleFonts.interTight(fontSize: 15, height: 1.5, color: AppTheme.ink),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _agentMessage() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 12, top: 2),
          child: message.isError
              ? Icon(Icons.error_outline_rounded, size: 20, color: AppTheme.ink2)
              : const SparkleIcon(size: 20),
        ),
        Expanded(
          child: GestureDetector(
            onLongPress: _agentActions,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.toolsUsed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final t in message.toolsUsed.toSet()) _toolPill(t)],
                    ),
                  ),
                MarkdownBody(
                  data: message.text,
                  selectable: true,
                  onTapLink: (_, href, __) {
                    final uri = href == null ? null : Uri.tryParse(href);
                    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
                      launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                  styleSheet: MarkdownStyleSheet(
                    p: GoogleFonts.interTight(
                      fontSize: 15,
                      color: message.isError ? AppTheme.ink2 : AppTheme.ink,
                      height: 1.55,
                    ),
                    strong: GoogleFonts.interTight(
                        fontSize: 15, color: AppTheme.ink, fontWeight: FontWeight.w600, height: 1.55),
                    listBullet: GoogleFonts.interTight(fontSize: 15, color: AppTheme.ink2),
                    a: GoogleFonts.interTight(
                        fontSize: 15, color: AppTheme.ink, decoration: TextDecoration.underline),
                    code: GoogleFonts.jetBrainsMono(
                      backgroundColor: AppTheme.surface2,
                      fontSize: 13,
                      color: AppTheme.ink,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.border),
                    ),
                  ),
                ),
                if (message.imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _image(message.imagePath!, width: 240),
                  ),
                if (_meta().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _meta(),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 9.5,
                        color: AppTheme.muted2,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _meta() {
    final parts = <String>[];
    if (message.instant) {
      parts.add('INSTANT');
    } else if (message.modelLabel != null && message.modelLabel!.isNotEmpty) {
      parts.add(message.modelLabel!.toUpperCase());
    }
    if (message.tokensPerSecond != null && message.tokensPerSecond! > 0) {
      parts.add('${message.tokensPerSecond!.toStringAsFixed(1)} TOK/S');
    }
    if (message.seconds != null && message.seconds! >= 0.05) {
      parts.add('${message.seconds!.toStringAsFixed(1)}S');
    }
    return parts.join('  ·  ');
  }

  Widget _toolPill(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: message.isError ? AppTheme.muted : AppTheme.success,
            ),
          ),
          const SizedBox(width: 8),
          Text(name, style: GoogleFonts.jetBrainsMono(fontSize: 11, color: AppTheme.ink2)),
        ],
      ),
    );
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Copied'),
      duration: Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _agentActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.copy_rounded, color: AppTheme.ink2),
              title: Text('Copy', style: GoogleFonts.interTight(color: AppTheme.ink)),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: Icon(Icons.flag_outlined, color: AppTheme.ink2),
              title: Text('Report this response', style: GoogleFonts.interTight(color: AppTheme.ink)),
              subtitle: Text('Tell the developer it was offensive, harmful or wrong',
                  style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'report'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') _copy();
    if (action == 'report') await _report();
  }

  Future<void> _report() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppTheme.surface,
        title: Text('What\'s wrong with it?',
            style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
        children: [
          for (final r in ReportService.reasons)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(r, style: GoogleFonts.interTight(color: AppTheme.ink2, fontSize: 15)),
              ),
            ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await ReportService().report(
      response: message.text,
      reason: reason,
      model: message.modelLabel,
    );
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(switch (result) {
        ReportResult.sent => 'Thanks. The report was sent to the developer.',
        ReportResult.emailOpened => 'Thanks. Send the email to finish the report.',
        ReportResult.unavailable => 'Reporting isn\'t set up in this build.',
      }),
    ));
  }
}
