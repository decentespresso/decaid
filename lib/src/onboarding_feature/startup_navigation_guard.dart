import 'package:flutter/widgets.dart';

class StartupNavigationLease {
  const StartupNavigationLease({required this.route, required this.generation});

  final Route<dynamic>? route;
  final int generation;
}

class StartupNavigationGuard extends NavigatorObserver {
  Route<dynamic>? _topRoute;
  int _generation = 0;

  Route<dynamic>? get topRoute => _topRoute;
  int get generation => _generation;

  StartupNavigationLease lease() =>
      StartupNavigationLease(route: _topRoute, generation: _generation);

  bool owns(StartupNavigationLease lease) =>
      lease.route != null &&
      identical(lease.route, _topRoute) &&
      lease.generation == _generation;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    if (identical(topRoute, _topRoute)) return;
    _topRoute = topRoute;
    _generation++;
  }
}
