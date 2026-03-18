// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'qb_ignore_keyword.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class QbIgnoreKeywordAdapter extends TypeAdapter<QbIgnoreKeyword> {
  @override
  final int typeId = 6;

  @override
  QbIgnoreKeyword read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return QbIgnoreKeyword(
      keyword:   fields[0] as String? ?? '',
      isDefault: fields[1] as bool?   ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, QbIgnoreKeyword obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.keyword)
      ..writeByte(1)
      ..write(obj.isDefault);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QbIgnoreKeywordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
