import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import 'design_components.dart';

/// Chat bubble — user messages render as a grey rounded pill on the right,
/// agent messages render as plain text under a sparkle icon, mirroring the
/// design's `.msg-user` / `.msg-agent` styles.
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
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _slide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    if (!widget.message.skipEntrance) {
      _controller.forward();
    }
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

  Widget _userMessage() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: GestureDetector(
            onLongPress: _copy,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
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
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(message.imagePath!),
                            width: 220,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    if (message.text.isNotEmpty)
                      Text(
                        message.text,
                        style: GoogleFonts.interTight(
                          fontSize: 15,
                          height: 1.5,
                          color: AppTheme.ink,
                        ),
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
        const Padding(
          padding: EdgeInsets.only(right: 12, top: 2),
          child: SparkleIcon(size: 20),
        ),
        Expanded(
          child: GestureDetector(
            onLongPress: _copy,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.toolName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _toolPill(message.toolName!),
                  ),
                MarkdownBody(
                  data: message.text,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    p: GoogleFonts.interTight(
                      fontSize: 15,
                      color: AppTheme.ink,
                      height: 1.55,
                    ),
                    strong: GoogleFonts.interTight(
                      fontSize: 15,
                      color: AppTheme.ink,
                      fontWeight: FontWeight.w600,
                      height: 1.55,
                    ),
                    code: GoogleFonts.jetBrainsMono(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.border),
                    ),
                  ),
                ),
                if (message.tps != null || message.toolName != null)
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
    if (message.toolName != null) {
      parts.add('TOOL: ${message.toolName!.toUpperCase()}');
    }
    if (message.tps != null) {
      parts.add('${message.tps!.toStringAsFixed(1)} TPS');
    }
    if (message.evalTime != null) {
      parts.add('${message.evalTime!.toStringAsFixed(1)}S');
    }
    parts.add('LOCAL · ON-DEVICE');
    return parts.join('  ·  ');
  }

  Widget _toolPill(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              color: AppTheme.success,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.success.withValues(alpha: 0.16),
                  blurRadius: 0,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            name,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11,
              color: AppTheme.ink2,
            ),
          ),
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
}
