// GENERATED CODE - DO NOT MODIFY BY HAND
part of 'qb_customer.dart';

class QbCustomerAdapter extends TypeAdapter<QbCustomer> {
  @override
  final int typeId = 5;

  @override
  QbCustomer read(BinaryReader reader) {
    final n = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < n; i++) reader.readByte(): reader.read(),
    };
    return QbCustomer(
      name: fields[0] as String,
      accountNo: fields[1] as String? ?? '',
      email: fields[2] as String? ?? '',
      phone: fields[3] as String? ?? '',
      address: fields[4] as String? ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, QbCustomer obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)..write(obj.name)
      ..writeByte(1)..write(obj.accountNo)
      ..writeByte(2)..write(obj.email)
      ..writeByte(3)..write(obj.phone)
      ..writeByte(4)..write(obj.address);
  }

  @override
  int get hashCode => typeId.hashCode;
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QbCustomerAdapter && typeId == other.typeId;
}
