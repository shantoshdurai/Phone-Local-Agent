import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/chat_message.dart';

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
      duration: const Duration(milliseconds: 280),
      value: widget.message.skipEntrance ? 1.0 : 0.0,
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _slide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
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
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            mainAxisAlignment:
                message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!message.isUser)
                const Padding(
                  padding: EdgeInsets.only(right: 12.0, top: 4),
                  child: Icon(Icons.auto_awesome_rounded,
                      size: 20, color: Colors.white),
                ),
              Flexible(
                child: GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: message.isUser
                          ? const Color(0xFF2F2F2F)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.imagePath != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(File(message.imagePath!),
                                  width: 200, fit: BoxFit.cover),
                            ),
                          ),
                        message.isUser
                            ? Text(message.text,
                                style: GoogleFonts.outfit(
                                    fontSize: 17, color: Colors.white))
                            : MarkdownBody(
                                data: message.text,
                                selectable: true,
                                styleSheet: MarkdownStyleSheet(
                                  p: GoogleFonts.outfit(
                                      fontSize: 17,
                                      color: Colors.white,
                                      height: 1.5),
                                  strong: GoogleFonts.outfit(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white),
                                  code: GoogleFonts.firaCode(
                                    backgroundColor:
                                        Colors.white.withValues(alpha: 0.1),
                                    fontSize: 14,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                        // Inference stats
                        if (!message.isUser &&
                            (message.tps != null || message.toolName != null))
                          Padding(
                            padding: const EdgeInsets.only(top: 12.0),
                            child: Text(
                              '${message.toolName != null ? 'Tool: ${message.toolName} • ' : ''}${message.tps?.toStringAsFixed(1) ?? '0.0'} TPS • ${message.evalTime?.toStringAsFixed(1) ?? '0.0'}s • Local AI',
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: Colors.white38),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (message.isUser) const SizedBox(width: 40),
            ],
          ),
        ),
      ),
    );
  }
}
