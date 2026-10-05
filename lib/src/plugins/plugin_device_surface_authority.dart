import 'plugin_manifest.dart';

class PluginDeviceSurfaceAuthority {
  final String pluginId;
  final List<PluginDeviceSurface> declaredSurfaces;

  PluginDeviceSurfaceAuthority({
    required this.pluginId,
    required List<PluginDeviceSurface> surfaces,
  }) : declaredSurfaces = List.unmodifiable(surfaces);

  List<Map<String, String>> resolve(
    String deviceId, {
    List<String>? available,
  }) => List.unmodifiable(
    declaredSurfaces
        .where((surface) => available == null || available.contains(surface.id))
        .map(
          (surface) => Map<String, String>.unmodifiable({
            'id': surface.id,
            'role': surface.role,
            if (surface.label != null) 'label': surface.label!,
            'href': Uri(
              pathSegments: [
                '',
                'api',
                'v1',
                'plugins',
                pluginId,
                surface.endpoint,
              ],
              queryParameters: {'ui': '1', 'deviceId': deviceId},
            ).toString(),
          }),
        ),
  );
}
