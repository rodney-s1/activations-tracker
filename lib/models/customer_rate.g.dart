// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'customer_rate.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CustomerRateAdapter extends TypeAdapter<CustomerRate> {
  @override
  final int typeId = 2;

  @override
  CustomerRate read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CustomerRate(
      customerName: fields[0] as String,
      overrideMonthlyRate: fields[1] as double?,
      notes: fields[2] as String? ?? '',
      lastUpdated: fields[3] as DateTime?,
      ratePlanLabel: fields[4] as String? ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, CustomerRate obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.customerName)
      ..writeByte(1)
      ..write(obj.overrideMonthlyRate)
      ..writeByte(2)
      ..write(obj.notes)
      ..writeByte(3)
      ..write(obj.lastUpdated)
      ..writeByte(4)
      ..write(obj.ratePlanLabel);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerRateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
