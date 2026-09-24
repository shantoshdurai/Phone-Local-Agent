import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/agent/agent_service.dart';
import '../services/memory_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// What the assistant remembers about the user. Stored only on the phone.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _memory = MemoryService.instance;
  final _input = TextEditingController();
  List<Memory> _items = [];
  bool _enabled = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    if (_changed) AgentService().refreshMemory();
    super.dispose();
  }

  Future<void> _load() async {
    final items = await _memory.all();
    final enabled = await _memory.enabled();
    if (!mounted) return;
    setState(() {
      _items = items.reversed.toList();
      _enabled = enabled;
    });
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    await _memory.add(text);
    _input.clear();
    _changed = true;
    await _load();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Forget everything?', style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
        content: Text('All ${_items.length} saved facts will be deleted.', style: GoogleFonts.interTight(color: AppTheme.ink2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Forget all', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _memory.clear();
    _changed = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(icon: Icons.arrow_back_rounded, onPressed: () => Navigator.maybePop(context)),
              title: Text('Memory',
                  style: GoogleFonts.interTight(
                      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
              trailing: _items.isEmpty
                  ? null
                  : HeaderIconButton(icon: Icons.delete_sweep_outlined, size: 20, onPressed: _clearAll),
            ),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  Text(
                    'Say "remember that…" in a chat and it\'s saved here. When memory is on, the assistant '
                    'sees these facts in every chat. They never leave your phone unless you use a cloud '
                    'model, which receives them with your messages.',
                    style: GoogleFonts.interTight(fontSize: 13, height: 1.5, color: AppTheme.ink2),
                  ),
                  const SizedBox(height: 12),
                  SettingsGroup(children: [
                    SettingsCell(
                      isFirst: true,
                      title: 'Use memory in chats',
                      subtitle: _enabled ? 'On' : 'Off: saved facts are kept but not used',
                      trailing: DesignSwitch(
                        value: _enabled,
                        onChanged: (v) async {
                          await _memory.setEnabled(v);
                          _changed = true;
                          setState(() => _enabled = v);
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _input,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _add(),
                    style: GoogleFonts.interTight(color: AppTheme.ink),
                    decoration: InputDecoration(
                      hintText: 'Add something to remember',
                      suffixIcon: IconButton(icon: Icon(Icons.add_rounded, color: AppTheme.ink), onPressed: _add),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                        child: Text('Nothing saved yet.', style: GoogleFonts.interTight(color: AppTheme.muted)),
                      ),
                    ),
                  for (final m in _items)
                    Dismissible(
                      key: ValueKey(m.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: Icon(Icons.delete_outline_rounded, color: AppTheme.error),
                      ),
                      onDismissed: (_) async {
                        await _memory.delete(m.id);
                        _changed = true;
                        _items.removeWhere((x) => x.id == m.id);
                        setState(() {});
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.bookmark_outline_rounded, size: 18, color: AppTheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(m.text,
                                  style: GoogleFonts.interTight(fontSize: 14, height: 1.45, color: AppTheme.ink)),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
