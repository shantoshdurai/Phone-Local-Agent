import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Chat history persistence (sessions + messages).
class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  /// Oldest sessions beyond this are pruned. The old limit of 5 silently
  /// deleted users' chats.
  static const int maxSessions = 50;

  Database? _database;

  Future<Database> get database async {
    return _database ??= await _initDatabase();
  }

  Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), 'agent_memory.db');
    return openDatabase(
      path,
      version: 5,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS chat_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          role TEXT,
          content TEXT,
          timestamp TEXT
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT,
          created_at TEXT
        )
      ''');
      await db.execute('ALTER TABLE chat_history ADD COLUMN session_id INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE chat_history ADD COLUMN meta TEXT');
      // The old app saved its canned greeting into every chat, which was then
      // replayed to the model as if it had said it.
      await db.delete('chat_history', where: 'role = ? AND content LIKE ?', whereArgs: [
        'assistant',
        "Hello! I'm your local AI agent. I have loaded my tools.%",
      ]);
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE chat_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT,
        content TEXT,
        timestamp TEXT,
        session_id INTEGER,
        meta TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        created_at TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_history_session ON chat_history(session_id)');
  }

  Future<void> saveMessage(
    String role,
    String content,
    int sessionId, {
    Map<String, dynamic>? meta,
  }) async {
    final db = await database;
    await db.insert('chat_history', {
      'role': role,
      'content': content,
      'timestamp': DateTime.now().toIso8601String(),
      'session_id': sessionId,
      'meta': meta == null || meta.isEmpty ? null : jsonEncode(meta),
    });
  }

  Future<List<Map<String, dynamic>>> getChatHistory(int sessionId) async {
    final db = await database;
    return db.query(
      'chat_history',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
  }

  static Map<String, dynamic> decodeMeta(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// (user, assistant) pairs for replaying a session to a model. Error
  /// replies are skipped so a failure isn't fed back as conversation.
  Future<List<(String, String)>> getExchanges(int sessionId) async {
    final rows = await getChatHistory(sessionId);
    final pairs = <(String, String)>[];
    String? pendingUser;
    for (final row in rows) {
      final role = row['role'] as String?;
      final content = (row['content'] as String?)?.trim() ?? '';
      if (role == 'user') {
        pendingUser = content;
      } else if (role == 'assistant' && pendingUser != null) {
        final meta = decodeMeta(row['meta']);
        if (meta['error'] != true && content.isNotEmpty) {
          pairs.add((pendingUser, content));
        }
        pendingUser = null;
      }
    }
    return pairs;
  }

  Future<int> createSession(String title) async {
    final db = await database;
    final sessions = await db.query('sessions', orderBy: 'id ASC');
    if (sessions.length >= maxSessions) {
      for (final s in sessions.take(sessions.length - maxSessions + 1)) {
        await deleteSession(s['id'] as int);
      }
    }
    return db.insert('sessions', {
      'title': title,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getSessions() async {
    final db = await database;
    return db.query('sessions', orderBy: 'id DESC');
  }

  Future<Map<String, dynamic>?> getSession(int sessionId) async {
    final db = await database;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [sessionId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> messageCount(int sessionId) async {
    final db = await database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM chat_history WHERE session_id = ?', [sessionId]);
    return (result.first['n'] as int?) ?? 0;
  }

  Future<void> deleteSession(int sessionId) async {
    final db = await database;
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
    await db.delete('chat_history', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  /// Removes sessions that never got a message (abandoned "New Chat"s).
  Future<void> deleteEmptySessions({int? except}) async {
    final db = await database;
    await db.rawDelete(
      'DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session_id FROM chat_history WHERE session_id IS NOT NULL)'
      '${except != null ? ' AND id != ?' : ''}',
      [if (except != null) except],
    );
  }

  Future<void> updateSessionTitle(int sessionId, String title) async {
    final db = await database;
    await db.update('sessions', {'title': title}, where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('chat_history');
    await db.delete('sessions');
  }
}
