import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';

typedef PageCursor<T> =
    Future<List<T>> Function(
      int limit, {
      DateTime? afterTimestamp,
      DateTime? afterCreatedAt,
      String? afterId,
    });

class BackupDataSources {
  final PageCursor<ShotRecord> pageShots;

  final PageCursor<SteamRecord> pageSteams;

  final PageCursor<Bean> pageBeans;

  final PageCursor<Grinder> pageGrinders;

  const BackupDataSources({
    required this.pageShots,
    required this.pageSteams,
    required this.pageBeans,
    required this.pageGrinders,
  });
}
