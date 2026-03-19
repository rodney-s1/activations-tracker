// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'qb_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class QbItemAdapter extends TypeAdapter<QbItem> {
  @override
  final int typeId = 8;

  @override
  QbItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return QbItem(
      item:        fields[0] as String,
      description: fields[1] as String,
      cost:        (fields[2] as num).toDouble(),
      price:       (fields[3] as num).toDouble(),
    );
  }

  @override
  void write(BinaryWriter writer, QbItem obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.item)
      ..writeByte(1)
      ..write(obj.description)
      ..writeByte(2)
      ..write(obj.cost)
      ..writeByte(3)
      ..write(obj.price);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QbItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
