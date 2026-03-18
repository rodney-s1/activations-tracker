// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'customer_plan_code.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CustomerPlanCodeAdapter extends TypeAdapter<CustomerPlanCode> {
  @override
  final int typeId = 4;

  @override
  CustomerPlanCode read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CustomerPlanCode(
      customerName: fields[0] as String,
      planCode: fields[1] as String,
      customerPrice: fields[2] as double,
      notes: fields[3] as String,
      lastUpdated: fields[4] as DateTime?,
      requiredRpc: fields[5] as String? ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, CustomerPlanCode obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.customerName)
      ..writeByte(1)
      ..write(obj.planCode)
      ..writeByte(2)
      ..write(obj.customerPrice)
      ..writeByte(3)
      ..write(obj.notes)
      ..writeByte(4)
      ..write(obj.lastUpdated)
      ..writeByte(5)
      ..write(obj.requiredRpc);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerPlanCodeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
