import '../../client_api/objects.dart';

/// 对应 DialogsAdapter.itemInternals：先投影行，再按会话身份绑定视图。
/// 不在这里重排业务数据，置顶/时间顺序仍由 ChatStore 决定。
class HomeDialogList {
  HomeDialogList(List<Chat> chats)
    : visible = List.unmodifiable(chats.where((chat) => !chat.archived)),
      archived = List.unmodifiable(chats.where((chat) => chat.archived)) {
    for (var i = 0; i < visible.length; i++) {
      _indices[visible[i].id] = i + (hasArchive ? 1 : 0);
    }
  }

  final List<Chat> visible;
  final List<Chat> archived;
  final Map<String, int> _indices = {};

  bool get hasArchive => archived.isNotEmpty;
  int get length => visible.length + (hasArchive ? 1 : 0);
  bool isArchive(int index) => hasArchive && index == 0;
  Chat chatAt(int index) => visible[index - (hasArchive ? 1 : 0)];
  int? indexOf(String chatId) => _indices[chatId];

  /// 显式打开的归档会话仍保留；失效的选择回退到主列表首项。
  static String? resolveSelected(List<Chat> chats, String? selectedId) {
    if (chats.isEmpty) return null;
    if (selectedId != null && chats.any((chat) => chat.id == selectedId)) {
      return selectedId;
    }
    return chats.where((chat) => !chat.archived).firstOrNull?.id ??
        chats.first.id;
  }
}
