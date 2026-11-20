import 'package:flutter/material.dart';

import '../../common.dart';

const kOptionMobilePanelActions = 'mobile-panel-actions';

/// The session panel's quick actions in their default order: id, icon and
/// translation key. Disconnect is not listed, it always comes last.
const kPanelQuickActions = <(String, IconData, String)>[
  ('keyboard', Icons.keyboard, 'Keyboard'),
  ('fn-keys', Icons.dialpad, 'Function keys'),
  ('send-text', Icons.edit_note, 'Send text'),
  ('touch-mode', Icons.mouse, 'Trackpad mode'),
  ('game-keys', Icons.sports_esports_outlined, 'Game keys'),
  ('screenshot', Icons.photo_camera_outlined, 'Take screenshot'),
  ('record', Icons.videocam_outlined, 'Recording'),
  ('privacy-mode', Icons.visibility_off_outlined, 'Privacy mode'),
  ('lock', Icons.lock_outline, 'Insert Lock'),
  ('restart', Icons.restart_alt, 'Restart remote device'),
  ('landscape', Icons.screen_rotation, 'Landscape'),
  ('gestures', Icons.gesture, 'Gestures'),
  ('file-transfer', Icons.folder_outlined, 'Transfer file'),
  ('chat', Icons.chat_bubble_outline, 'Chat'),
  ('display-settings', Icons.tv, 'Display Settings'),
];

typedef PanelActionEntry = ({String id, bool shown});

/// Reads the saved order: ids separated by commas, a hidden one starts with
/// `-`. Ids this version does not have are dropped, and actions added since
/// the order was saved are shown where the default order has them.
List<PanelActionEntry> parsePanelActions(String saved) {
  final known = kPanelQuickActions.map((e) => e.$1).toList();
  final entries = <PanelActionEntry>[];
  for (final part in saved.split(',')) {
    final hidden = part.startsWith('-');
    final id = hidden ? part.substring(1) : part;
    if (!known.contains(id) || entries.any((e) => e.id == id)) continue;
    entries.add((id: id, shown: !hidden));
  }
  for (var i = 0; i < known.length; i++) {
    if (entries.any((e) => e.id == known[i])) continue;
    final before = i == 0 ? -1 : entries.indexWhere((e) => e.id == known[i - 1]);
    entries.insert(before + 1, (id: known[i], shown: true));
  }
  return entries;
}

String formatPanelActions(List<PanelActionEntry> entries) =>
    entries.map((e) => e.shown ? e.id : '-${e.id}').join(',');

/// Lets the user pick which quick actions the panel shows and in what order.
/// Returns null when cancelled.
Future<List<PanelActionEntry>?> showPanelActionsEditor(
    BuildContext context, List<PanelActionEntry> entries,
    {String Function(String) tr = translate}) {
  return showDialog<List<PanelActionEntry>>(
    context: context,
    builder: (context) => _PanelActionsEditor(entries: entries, tr: tr),
  );
}

class _PanelActionsEditor extends StatefulWidget {
  const _PanelActionsEditor({required this.entries, required this.tr});
  final List<PanelActionEntry> entries;
  final String Function(String) tr;

  @override
  State<_PanelActionsEditor> createState() => _PanelActionsEditorState();
}

class _PanelActionsEditorState extends State<_PanelActionsEditor> {
  late var _entries = [...widget.entries];

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return AlertDialog(
      title: Text(tr('Quick actions')),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: ReorderableListView.builder(
          shrinkWrap: true,
          buildDefaultDragHandles: false,
          itemCount: _entries.length,
          onReorder: (from, to) => setState(() {
            final moved = _entries.removeAt(from);
            _entries.insert(to > from ? to - 1 : to, moved);
          }),
          itemBuilder: (context, i) {
            final entry = _entries[i];
            final (_, icon, label) =
                kPanelQuickActions.firstWhere((e) => e.$1 == entry.id);
            return Row(
              key: ValueKey(entry.id),
              children: [
                Checkbox(
                  value: entry.shown,
                  onChanged: (v) => setState(() =>
                      _entries[i] = (id: entry.id, shown: v ?? entry.shown)),
                ),
                Icon(icon, size: 20),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(tr(label),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.drag_handle),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => setState(() => _entries = parsePanelActions('')),
            child: Text(tr('Default'))),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel'))),
        TextButton(
            onPressed: () => Navigator.pop(context, _entries),
            child: Text(tr('OK'))),
      ],
    );
  }
}
