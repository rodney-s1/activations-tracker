// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'serial_filter_rule.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SerialFilterRuleAdapter extends TypeAdapter<SerialFilterRule> {
  @override
  final int typeId = 1;

  @override
  SerialFilterRule read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SerialFilterRule(
      prefix: fields[0] as String,
      isExcluded: fields[1] as bool,
      label: fields[2] as String,
      isSystem: fields[3] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, SerialFilterRule obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.prefix)
      ..writeByte(1)
      ..write(obj.isExcluded)
      ..writeByte(2)
      ..write(obj.label)
      ..writeByte(3)
      ..write(obj.isSystem);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SerialFilterRuleAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
