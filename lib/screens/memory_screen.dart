import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/memory_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// The user's view of what the assistant remembers.
///
/// Deliberately boring and complete: every captured fact is listed, can be
/// deleted individually, and can be wiped in one tap. An assistant with
/// invisible memory loses trust the first time it says something the user
/// doesn't remember telling it.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final MemoryService _memory = MemoryService.instance;
  final TextEditingController _controller = TextEditingController();

  List<MemoryFact> _facts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final facts = await _memory.all();
    if (!mounted) return;
    setState(() {
      _facts = facts;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final fact = await _memory.add(text, kind: FactKind.other);
    _controller.clear();
    if (!mounted) return;
    if (fact == null) {
      _snack('That is already in memory.');
    }
    await _load();
  }

  Future<void> _delete(MemoryFact fact) async {
    await _memory.remove(fact.id);
    await _load();
    if (!mounted) return;
    _snack('Forgot "${fact.text}".');
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          'Forget everything?',
          style: GoogleFonts.interTight(
              color: AppTheme.ink, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          'The assistant will start from scratch. Chat history is not affected.',
          style: GoogleFonts.interTight(color: AppTheme.ink2, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.interTight(color: AppTheme.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Forget all',
                style: GoogleFonts.interTight(
                    color: AppTheme.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _memory.clear();
    await _load();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.pop(context),
              ),
              title: Text(
                'Memory',
                style: GoogleFonts.interTight(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: AppTheme.ink,
                ),
              ),
              trailing: _facts.isEmpty
                  ? null
                  : TextButton(
                      onPressed: _clearAll,
                      child: Text(
                        'Clear',
                        style: GoogleFonts.interTight(
                            fontSize: 12, color: AppTheme.muted),
                      ),
                    ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: AppTheme.muted,
                        ),
                      ),
                    )
                  : ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                      children: [
                        Text(
                          'What the assistant\nremembers',
                          style: GoogleFonts.interTight(
                            fontSize: 26,
                            height: 1.12,
                            letterSpacing: -0.8,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Saved on this device and used to personalise answers. '
                          'Delete anything you do not want it to know.',
                          style: GoogleFonts.interTight(
                            fontSize: 13,
                            height: 1.5,
                            color: AppTheme.ink2,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _addCard(),
                        const SizedBox(height: 20),
                        if (_facts.isEmpty)
                          _emptyState()
                        else ...[
                          const Eyebrow('SAVED'),
                          const SizedBox(height: 10),
                          ..._facts.map((f) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _factRow(f),
                              )),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _add(),
              style: GoogleFonts.interTight(fontSize: 13.5, color: AppTheme.ink),
              cursorColor: AppTheme.ink,
              decoration: InputDecoration(
                hintText: 'e.g. I prefer metric units',
                hintStyle:
                    GoogleFonts.interTight(fontSize: 13.5, color: AppTheme.muted2),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          TextButton(
            onPressed: _add,
            child: Text(
              'Add',
              style: GoogleFonts.interTight(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          const Icon(Icons.psychology_outlined, size: 26, color: AppTheme.muted2),
          const SizedBox(height: 12),
          Text(
            'Nothing yet.',
            style: GoogleFonts.interTight(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Say things like "my name is …", "I live in …" or "remember that …" '
            'and they will show up here.',
            textAlign: TextAlign.center,
            style: GoogleFonts.interTight(
              fontSize: 12.5,
              height: 1.5,
              color: AppTheme.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _factRow(MemoryFact fact) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(_iconFor(fact.kind), size: 16, color: AppTheme.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              fact.text,
              style: GoogleFonts.interTight(
                fontSize: 13.5,
                height: 1.4,
                color: AppTheme.ink,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Forget this',
            onPressed: () => _delete(fact),
            icon: const Icon(Icons.close_rounded, size: 16, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(FactKind kind) {
    switch (kind) {
      case FactKind.identity:
        return Icons.person_outline_rounded;
      case FactKind.preference:
        return Icons.tune_rounded;
      case FactKind.other:
        return Icons.sticky_note_2_outlined;
    }
  }
}
