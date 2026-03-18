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

  /// True = "Charged Upon Activation" customer.
  /// CUA customers are only billed for Active (not Suspended / Never Activated)
  /// devices. Auto-set from Column AK on CSV import (contains "Charge Upon Activation").
  /// Can also be toggled manually.
  @HiveField(5, defaultValue: false)
  bool isCua;

  /// Raw value from Column AK (Job Type) in the QB Customer List CSV.
  /// Examples: "Standard", "Charge Upon Activation", "Charge Upon Activation:Hanover",
  ///           "Standard:TCS", "Reseller", "In Collections", ""
  @HiveField(6, defaultValue: '')
  String jobType;

  QbCustomer({
    required this.name,
    this.accountNo = '',
    this.email = '',
    this.phone = '',
    this.address = '',
    this.isCua = false,
    this.jobType = '',
  });
}
