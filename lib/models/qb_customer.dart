// QB customer entry — imported from QuickBooks customer list CSV
import 'package:hive/hive.dart';
part 'qb_customer.g.dart';

@HiveType(typeId: 5)
class QbCustomer extends HiveObject {
  @HiveField(0)
  String name; // QB "Customer" column — the billing name

  @HiveField(1)
  String accountNo; // QB Account No.

  @HiveField(2)
  String email;

  @HiveField(3)
  String phone;

  @HiveField(4)
  String address;

  QbCustomer({
    required this.name,
    this.accountNo = '',
    this.email = '',
    this.phone = '',
    this.address = '',
  });
}
