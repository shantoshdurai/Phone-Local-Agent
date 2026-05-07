import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'file_service.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'agent_memory.db');
    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE files ADD COLUMN last_accessed TEXT');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE,
        name TEXT,
        type TEXT,
        size INTEGER,
        modified_date TEXT,
        last_accessed TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE device_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT UNIQUE,
        value TEXT,
        timestamp TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE memory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_query TEXT,
        agent_action TEXT,
        result TEXT,
        timestamp TEXT
      )
    ''');
  }

  // --- Files Methods ---
  Future<void> insertFiles(List<FileMetadata> files) async {
    final db = await database;
    Batch batch = db.batch();
    for (var file in files) {
      batch.insert(
        'files',
        file.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> searchFiles(String query) async {
    final db = await database;
    return await db.query(
      'files',
      where: 'name LIKE ?',
      whereArgs: ['%$query%'],
    );
  }

  // --- Device State Methods ---
  Future<void> updateDeviceState(Map<String, dynamic> state) async {
    final db = await database;
    Batch batch = db.batch();
    state.forEach((key, value) {
      batch.insert(
        'device_state',
        {
          'key': key,
          'value': value.toString(),
          'timestamp': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  Future<Map<String, dynamic>> getDeviceState() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('device_state');
    return {for (var item in maps) item['key'] as String: item['value']};
  }

  // --- Memory Methods ---
  Future<void> insertMemory(String query, String action, String result) async {
    final db = await database;
    await db.insert(
      'memory',
      {
        'user_query': query,
        'agent_action': action,
        'result': result,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<List<Map<String, dynamic>>> getRecentMemory(int limit) async {
    final db = await database;
    return await db.query(
      'memory',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }
}
