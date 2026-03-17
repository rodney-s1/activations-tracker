// Model for a saved import session (stored in Hive)

import 'package:hive/hive.dart';

part 'import_session.g.dart';

@HiveType(typeId: 0)
class ImportSession extends HiveObject {
  @HiveField(0)
  String fileName;

  @HiveField(1)
  DateTime importedAt;

  @HiveField(2)
  String reportDateFrom;

  @HiveField(3)
  String reportDateTo;

  @HiveField(4)
  int totalDevices;

  @HiveField(5)
  int totalCustomers;

  @HiveField(6)
  double totalProratedCost;

  @HiveField(7)
  String rawCsvContent; // stored for history re-processing

  ImportSession({
    required this.fileName,
    required this.importedAt,
    required this.reportDateFrom,
    required this.reportDateTo,
    required this.totalDevices,
    required this.totalCustomers,
    required this.totalProratedCost,
    required this.rawCsvContent,
  });
}
