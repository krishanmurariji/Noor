import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/connection_provider.dart';
import 'noor_toast.dart';

/// Says so in the capsule at the top when the internet goes ("Offline ·
/// saved songs only") and when it is back ("Back online"), once each time,
/// wherever you are in the app. Nothing stays on screen in between.
class NoorOfflineAnnouncer extends ConsumerWidget {
  const NoorOfflineAnnouncer({super.key, required this.child});
  final Widget child;

  static const offlineText = 'Offline · saved songs only';
  static const onlineText = 'Back online';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<Connection>(connectionProvider, (prev, next) {
      if (prev == next) return;
      if (next == Connection.offline) {
        NoorToast.show(context, offlineText,
            duration: const Duration(seconds: 6));
      } else if (prev == Connection.offline) {
        NoorToast.show(context, onlineText);
      }
    });
    return child;
  }
}
