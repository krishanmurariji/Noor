import 'package:flutter_test/flutter_test.dart';
import 'package:noor/widgets/island_glyphs.dart';

/// Every message the app shows gets a symbol that fits it.
void main() {
  const cases = {
    'Offline · saved songs only': IslandKind.offline,
    'No connection — will resume when back online': IslandKind.offline,
    'Offline — playing downloaded songs': IslandKind.offline,
    "Can't reach YouTube from this network (DNS/connection problem)":
        IslandKind.offline,
    'Back online': IslandKind.online,
    'Rohan wants to join': IslandKind.knock,
    "You're in · Sunda": IslandKind.welcome,
    'Added to Road Trip ✓': IslandKind.welcome,
    'Created and added to Sufi ✓': IslandKind.welcome,
    "You're the star now": IslandKind.star,
    'Aanya is the star now': IslandKind.star,
    'Kabir asks to be the star': IslandKind.star,
    'Asked to be the star': IslandKind.star,
    'Zaid asked for Velvet Night': IslandKind.music,
    'Velvet Night plays next': IslandKind.music,
    'Velvet Night is in the queue': IslandKind.music,
    'Ask Aanya to play Velvet Night?': IslandKind.music,
    'Playing Kesariya': IslandKind.music,
    'Syncing everyone': IslandKind.sync,
    'Back in step with Aanya': IslandKind.sync,
    'Room code copied': IslandKind.copy,
    'Invite copied': IslandKind.copy,
    'Log copied to clipboard': IslandKind.copy,
    'Removed from your history': IslandKind.remove,
    'History cleared': IslandKind.remove,
    'You were removed from the room': IslandKind.remove,
    'The room has ended': IslandKind.remove,
    "You're no longer in the room": IslandKind.remove,
    'Updating Noor to build 180…': IslandKind.update,
    'Skipped "Old song" — unavailable': IslandKind.warning,
    'Could not play "Old song"': IslandKind.warning,
    "Couldn't reach the room · try again": IslandKind.warning,
    "You can't join this room": IslandKind.warning,
    'Not this time · the star said no': IslandKind.warning,
    'The room is full · 20 is the most': IslandKind.warning,
    'A playlist with this name already exists.': IslandKind.warning,
    'You can have up to 10 playlists.': IslandKind.warning,
    "You're offline. This song isn't saved yet.": IslandKind.offline,
    'YouTube is limiting requests from your network': IslandKind.warning,
    'Aanya picks the songs in this room': IslandKind.music,
  };
  for (final e in cases.entries) {
    test('"${e.key}" → ${e.value.name}', () {
      expect(islandKindFor(e.key), e.value);
    });
  }
}
