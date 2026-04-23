// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'plan_mapping.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PlanMappingAdapter extends TypeAdapter<PlanMapping> {
  @override
  final int typeId = 9;

  @override
  PlanMapping read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlanMapping(
      myAdminPlan: fields[0] as String,
      qbLabel: fields[1] as String,
      isDefault: fields[2] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, PlanMapping obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.myAdminPlan)
      ..writeByte(1)
      ..write(obj.qbLabel)
      ..writeByte(2)
      ..write(obj.isDefault);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlanMappingAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
