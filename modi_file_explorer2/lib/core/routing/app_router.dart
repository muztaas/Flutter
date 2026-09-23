import 'package:go_router/go_router.dart';
import '../../presentation/home/home_page.dart';
import '../../presentation/storage/storage_tab.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/storage',
      builder: (context, state) {
        final raw = state.uri.queryParameters['path'];
        final initial = raw == null ? null : Uri.decodeComponent(raw);
        return StorageTab(initialPath: initial);
      },
    ),
  ],
);
