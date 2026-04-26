import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class OfflineScanStore {
  OfflineScanStore._();

  static final OfflineScanStore instance = OfflineScanStore._();

  static const String dbName = 'offline_scanner_v1.db';
  static const int _dbVersion = 2;

  Database? _db;

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scan_context_cache (
        actor_key TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        status TEXT NOT NULL,
        scanner_enabled INTEGER NOT NULL,
        synced_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        payload_json TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS scan_ticket_cache (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_key TEXT NOT NULL,
        event_id TEXT NOT NULL,
        session_id TEXT,
        ticket_hash TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        avatar_local_path TEXT,
        avatar_remote_url TEXT,
        attendance_status TEXT,
        pending_sync INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        UNIQUE(actor_key, ticket_hash)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scan_ticket_actor_event ON scan_ticket_cache(actor_key, event_id)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS scan_ops_queue (
        id TEXT PRIMARY KEY,
        actor_key TEXT NOT NULL,
        role TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        ticket_hash TEXT NOT NULL,
        event_id TEXT,
        session_id TEXT,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_error TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scan_ops_actor_status ON scan_ops_queue(actor_key, status, next_retry_at)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS scan_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<bool> _columnExists(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    final rows = await db.rawQuery("PRAGMA table_info($table)");
    for (final row in rows) {
      final name = row['name']?.toString().trim().toLowerCase() ?? '';
      if (name == column.trim().toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  Future<void> _ensureColumn(
    DatabaseExecutor db, {
    required String table,
    required String column,
    required String definition,
  }) async {
    if (await _columnExists(db, table, column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  Future<void> _migrateSchema(DatabaseExecutor db) async {
    await _createSchema(db);

    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'role',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'actor_id',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'status',
      definition: "TEXT NOT NULL DEFAULT 'closed'",
    );
    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'scanner_enabled',
      definition: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'synced_at',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'expires_at',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_context_cache',
      column: 'payload_json',
      definition: "TEXT NOT NULL DEFAULT '{}'",
    );

    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'actor_key',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'event_id',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'session_id',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'ticket_hash',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'payload_json',
      definition: "TEXT NOT NULL DEFAULT '{}'",
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'avatar_local_path',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'avatar_remote_url',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'attendance_status',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'pending_sync',
      definition: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      table: 'scan_ticket_cache',
      column: 'updated_at',
      definition: "TEXT NOT NULL DEFAULT ''",
    );

    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'actor_key',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'role',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'actor_id',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'ticket_hash',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'event_id',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'session_id',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'payload_json',
      definition: "TEXT NOT NULL DEFAULT '{}'",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'status',
      definition: "TEXT NOT NULL DEFAULT 'pending'",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'attempt_count',
      definition: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'next_retry_at',
      definition: 'TEXT',
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'created_at',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'updated_at',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_ops_queue',
      column: 'last_error',
      definition: 'TEXT',
    );

    await _ensureColumn(
      db,
      table: 'scan_meta',
      column: 'value',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      table: 'scan_meta',
      column: 'updated_at',
      definition: "TEXT NOT NULL DEFAULT ''",
    );
  }

  Future<Database> _database() async {
    if (_db != null) return _db!;

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async => _createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async => _migrateSchema(db),
      onOpen: (db) async => _migrateSchema(db),
    );
    return _db!;
  }

  Future<void> upsertContextCache({
    required String actorKey,
    required String role,
    required String actorId,
    required String status,
    required bool scannerEnabled,
    required String syncedAtIso,
    required String expiresAtIso,
    required String payloadJson,
  }) async {
    final db = await _database();
    await db.insert(
      'scan_context_cache',
      {
        'actor_key': actorKey,
        'role': role,
        'actor_id': actorId,
        'status': status,
        'scanner_enabled': scannerEnabled ? 1 : 0,
        'synced_at': syncedAtIso,
        'expires_at': expiresAtIso,
        'payload_json': payloadJson,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getContextCache(String actorKey) async {
    final db = await _database();
    final rows = await db.query(
      'scan_context_cache',
      where: 'actor_key = ?',
      whereArgs: [actorKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  Future<void> deleteContextCache(String actorKey) async {
    final db = await _database();
    await db.delete(
      'scan_context_cache',
      where: 'actor_key = ?',
      whereArgs: [actorKey],
    );
  }

  Future<void> replaceTicketCacheForEvent({
    required String actorKey,
    required String eventId,
    required List<Map<String, dynamic>> rows,
  }) async {
    final db = await _database();
    await db.transaction((txn) async {
      await txn.delete(
        'scan_ticket_cache',
        where: 'actor_key = ? AND event_id = ?',
        whereArgs: [actorKey, eventId],
      );
      for (final row in rows) {
        await txn.insert(
          'scan_ticket_cache',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<Map<String, dynamic>?> getTicketCacheByHash({
    required String actorKey,
    required String ticketHash,
  }) async {
    final db = await _database();
    final rows = await db.query(
      'scan_ticket_cache',
      where: 'actor_key = ? AND ticket_hash = ?',
      whereArgs: [actorKey, ticketHash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  Future<List<Map<String, dynamic>>> listTicketCacheForEvent({
    required String actorKey,
    required String eventId,
  }) async {
    final db = await _database();
    final rows = await db.query(
      'scan_ticket_cache',
      where: 'actor_key = ? AND event_id = ?',
      whereArgs: [actorKey, eventId],
      orderBy: 'updated_at DESC, id DESC',
      limit: 5000,
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<List<Map<String, dynamic>>> listRecentTicketCache({
    required String actorKey,
    int limit = 250,
  }) async {
    final db = await _database();
    final rows = await db.query(
      'scan_ticket_cache',
      where: 'actor_key = ?',
      whereArgs: [actorKey],
      orderBy: 'updated_at DESC, id DESC',
      limit: limit,
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> clearTicketCacheForActor(String actorKey) async {
    final db = await _database();
    await db.delete(
      'scan_ticket_cache',
      where: 'actor_key = ?',
      whereArgs: [actorKey],
    );
  }

  Future<void> updateTicketCacheByHash({
    required String actorKey,
    required String ticketHash,
    required Map<String, dynamic> updates,
  }) async {
    final db = await _database();
    await db.update(
      'scan_ticket_cache',
      updates,
      where: 'actor_key = ? AND ticket_hash = ?',
      whereArgs: [actorKey, ticketHash],
    );
  }

  Future<String?> findPendingOperationId({
    required String actorKey,
    required String ticketHash,
    String sessionId = '',
  }) async {
    final db = await _database();
    final rows = await db.query(
      'scan_ops_queue',
      columns: ['id'],
      where:
          "actor_key = ? AND ticket_hash = ? AND COALESCE(session_id, '') = ? AND status = 'pending'",
      whereArgs: [actorKey, ticketHash, sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id']?.toString();
  }

  Future<void> enqueueOperation(Map<String, dynamic> row) async {
    final db = await _database();
    await db.insert(
      'scan_ops_queue',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> listDuePendingOperations(
    String actorKey,
  ) async {
    final db = await _database();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final rows = await db.query(
      'scan_ops_queue',
      where:
          "actor_key = ? AND status = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [actorKey, nowIso],
      orderBy: 'created_at ASC',
      limit: 500,
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> updateOperation({
    required String id,
    required Map<String, dynamic> updates,
  }) async {
    final db = await _database();
    await db.update(
      'scan_ops_queue',
      updates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> pendingCount(String actorKey) async {
    final db = await _database();
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM scan_ops_queue WHERE actor_key = ? AND status = 'pending'",
      [actorKey],
    );
    if (rows.isEmpty) return 0;
    final value = rows.first['c'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await _database();
    await db.insert(
      'scan_meta',
      {
        'key': key,
        'value': value,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasAnyScannerData() async {
    final db = await _database();
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM scan_context_cache) +
        (SELECT COUNT(*) FROM scan_ticket_cache) +
        (SELECT COUNT(*) FROM scan_ops_queue) AS c
    ''');
    if (rows.isEmpty) return false;
    final value = rows.first['c'];
    if (value is int) return value > 0;
    if (value is num) return value.toInt() > 0;
    return (int.tryParse(value?.toString() ?? '') ?? 0) > 0;
  }

  Future<void> clearAll() async {
    final db = await _database();
    await db.transaction((txn) async {
      await txn.delete('scan_context_cache');
      await txn.delete('scan_ticket_cache');
      await txn.delete('scan_ops_queue');
      await txn.delete('scan_meta');
    });
  }

  Future<Map<String, dynamic>> exportAll() async {
    final db = await _database();
    final contexts = await db.query('scan_context_cache');
    final tickets = await db.query('scan_ticket_cache');
    final queue = await db.query('scan_ops_queue');
    final meta = await db.query('scan_meta');
    return {
      'version': 1,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'scan_context_cache':
          contexts.map((row) => Map<String, dynamic>.from(row)).toList(),
      'scan_ticket_cache':
          tickets.map((row) => Map<String, dynamic>.from(row)).toList(),
      'scan_ops_queue':
          queue.map((row) => Map<String, dynamic>.from(row)).toList(),
      'scan_meta': meta.map((row) => Map<String, dynamic>.from(row)).toList(),
    };
  }

  Future<void> importAll(Map<String, dynamic> data) async {
    final db = await _database();
    final contexts = data['scan_context_cache'] is List
        ? List<Map<String, dynamic>>.from(
            (data['scan_context_cache'] as List).map(
              (row) => Map<String, dynamic>.from(row as Map),
            ),
          )
        : <Map<String, dynamic>>[];
    final tickets = data['scan_ticket_cache'] is List
        ? List<Map<String, dynamic>>.from(
            (data['scan_ticket_cache'] as List).map(
              (row) => Map<String, dynamic>.from(row as Map),
            ),
          )
        : <Map<String, dynamic>>[];
    final queue = data['scan_ops_queue'] is List
        ? List<Map<String, dynamic>>.from(
            (data['scan_ops_queue'] as List).map(
              (row) => Map<String, dynamic>.from(row as Map),
            ),
          )
        : <Map<String, dynamic>>[];
    final meta = data['scan_meta'] is List
        ? List<Map<String, dynamic>>.from(
            (data['scan_meta'] as List).map(
              (row) => Map<String, dynamic>.from(row as Map),
            ),
          )
        : <Map<String, dynamic>>[];

    await db.transaction((txn) async {
      await txn.delete('scan_context_cache');
      await txn.delete('scan_ticket_cache');
      await txn.delete('scan_ops_queue');
      await txn.delete('scan_meta');

      for (final row in contexts) {
        await txn.insert(
          'scan_context_cache',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in tickets) {
        await txn.insert(
          'scan_ticket_cache',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in queue) {
        await txn.insert(
          'scan_ops_queue',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in meta) {
        await txn.insert(
          'scan_meta',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }
}
