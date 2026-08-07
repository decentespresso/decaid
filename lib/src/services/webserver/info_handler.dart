import 'package:logging/logging.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class InfoHandler {
  final Logger _log = Logger('InfoHandler');

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/info', _infoHandler);
  }

  Future<Response> _infoHandler(Request request) async {
    _log.fine('Handling info request');
    final info = {
      'commit': BuildInfo.commit,
      'commitShort': BuildInfo.commitShort,
      'branch': BuildInfo.branch,
      'buildTime': BuildInfo.buildTime,
      'version': BuildInfo.version,
      'buildNumber': BuildInfo.buildNumber,
      'appStore': BuildInfo.appStore,
      'fullVersion': BuildInfo.fullVersion,
      'localIp': await _localIp(),
    };
    return jsonOk(info);
  }

  Future<String> _localIp() async {
    try {
      return await NetworkInfo().getWifiIP() ?? '';
    } catch (e, st) {
      _log.fine('Could not read local IP', e, st);
      return '';
    }
  }
}
