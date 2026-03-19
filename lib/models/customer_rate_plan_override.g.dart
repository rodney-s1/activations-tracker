// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'customer_rate_plan_override.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CustomerRatePlanOverrideAdapter
    extends TypeAdapter<CustomerRatePlanOverride> {
  @override
  final int typeId = 7;

  @override
  CustomerRatePlanOverride read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CustomerRatePlanOverride(
      customerName:  fields[0] as String,
      ratePlan:      fields[1] as String,
      customerPrice: (fields[2] as num).toDouble(),
      notes:         fields[3] as String? ?? '',
      lastUpdated:   fields[4] as DateTime?,
      yourCost:      (fields[5] as num?)?.toDouble() ?? 0.0,
    );
  }

  @override
  void write(BinaryWriter writer, CustomerRatePlanOverride obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.customerName)
      ..writeByte(1)
      ..write(obj.ratePlan)
      ..writeByte(2)
      ..write(obj.customerPrice)
      ..writeByte(3)
      ..write(obj.notes)
      ..writeByte(4)
      ..write(obj.lastUpdated)
      ..writeByte(5)
      ..write(obj.yourCost);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerRatePlanOverrideAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
