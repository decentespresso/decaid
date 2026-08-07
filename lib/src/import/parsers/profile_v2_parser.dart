import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';

class ProfileV2Parser {
  static ProfileRecord parse(Map<String, dynamic> json) {
    final profile = Profile.fromJson(json);
    return ProfileRecord.create(profile: profile);
  }
}
