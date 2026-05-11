import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/chat_message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.isUser)
            const Padding(
              padding: EdgeInsets.only(right: 12.0, top: 4),
              child: Icon(Icons.auto_awesome_rounded, size: 20, color: Colors.white),
            ),
          Flexible(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: message.text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                    color: message.isUser ? const Color(0xFF2F2F2F) : Colors.transparent,
                    borderRadius: BorderRadius.circular(18)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.imagePath != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(File(message.imagePath!), width: 200, fit: BoxFit.cover)),
                      ),
                    message.isUser
                        ? Text(message.text,
                            style: GoogleFonts.outfit(fontSize: 17, color: Colors.white))
                        : MarkdownBody(
                            data: message.text,
                            selectable: true,
                            styleSheet: MarkdownStyleSheet(
                              p: GoogleFonts.outfit(fontSize: 17, color: Colors.white, height: 1.5),
                              strong: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: Colors.white),
                              code: GoogleFonts.firaCode(
                                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                                  fontSize: 14,
                                  color: Colors.white70),
                            ),
                          ),
                    // Inference stats
                    if (!message.isUser && message.tps != null && message.evalTime != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12.0),
                        child: Text(
                          '${message.tps!.toStringAsFixed(1)} TPS • ${message.evalTime!.toStringAsFixed(1)}s • Local AI',
                          style: GoogleFonts.inter(fontSize: 11, color: Colors.white38),
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
    );
  }
}
