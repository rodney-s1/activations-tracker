// Manages import history using Hive for local persistence

import 'package:hive_flutter/hive_flutter.dart';
import '../models/import_session.dart';

class HistoryService {
  static const _boxName = 'import_history';
  static Box<ImportSession>? _box;

  static Future<void> init() async {
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ImportSessionAdapter());
    }
    _box = await Hive.openBox<ImportSession>(_boxName);
  }

  static Box<ImportSession> get box {
    if (_box == null) throw StateError('HistoryService not initialized');
    return _box!;
  }

  static Future<void> saveSession(ImportSession session) async {
    await box.add(session);
  }

  static List<ImportSession> getAllSessions() {
    final sessions = box.values.toList();
    // Sort newest first
    sessions.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return sessions;
  }

  static Future<void> deleteSession(int index) async {
    final key = box.keyAt(index);
    await box.delete(key);
  }

  static Future<void> clearAll() async {
    await box.clear();
  }

  static int get count => box.length;
}
