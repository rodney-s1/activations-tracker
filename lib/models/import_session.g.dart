// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'import_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ImportSessionAdapter extends TypeAdapter<ImportSession> {
  @override
  final int typeId = 0;

  @override
  ImportSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ImportSession(
      fileName: fields[0] as String,
      importedAt: fields[1] as DateTime,
      reportDateFrom: fields[2] as String,
      reportDateTo: fields[3] as String,
      totalDevices: fields[4] as int,
      totalCustomers: fields[5] as int,
      totalProratedCost: fields[6] as double,
      rawCsvContent: fields[7] as String,
    );
  }

  @override
  void write(BinaryWriter writer, ImportSession obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.fileName)
      ..writeByte(1)
      ..write(obj.importedAt)
      ..writeByte(2)
      ..write(obj.reportDateFrom)
      ..writeByte(3)
      ..write(obj.reportDateTo)
      ..writeByte(4)
      ..write(obj.totalDevices)
      ..writeByte(5)
      ..write(obj.totalCustomers)
      ..writeByte(6)
      ..write(obj.totalProratedCost)
      ..writeByte(7)
      ..write(obj.rawCsvContent);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImportSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
