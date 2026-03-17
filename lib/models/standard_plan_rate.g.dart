// GENERATED CODE - DO NOT MODIFY BY HAND
part of 'standard_plan_rate.dart';

class StandardPlanRateAdapter extends TypeAdapter<StandardPlanRate> {
  @override
  final int typeId = 3;

  @override
  StandardPlanRate read(BinaryReader reader) {
    final n = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < n; i++) reader.readByte(): reader.read(),
    };
    return StandardPlanRate(
      planKey: fields[0] as String,
      keyword: fields[1] as String,
      yourCost: fields[2] as double,
      sortOrder: fields[3] as int? ?? 99,
    );
  }

  @override
  void write(BinaryWriter writer, StandardPlanRate obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)..write(obj.planKey)
      ..writeByte(1)..write(obj.keyword)
      ..writeByte(2)..write(obj.yourCost)
      ..writeByte(3)..write(obj.sortOrder);
  }

  @override
  int get hashCode => typeId.hashCode;
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StandardPlanRateAdapter && typeId == other.typeId;
}
