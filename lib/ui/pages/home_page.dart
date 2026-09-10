/// L4 主页面：Telegram Desktop 风格三栏布局
///
/// ┌──────────────┬────────────────────────────────────┐
/// │ 搜索 / 会话列表 │  标题栏                             │
/// │              │  消息流（气泡）                      │
/// │              │  输入栏                             │
/// └──────────────┴────────────────────────────────────┘
///
/// 当前为 UI 原型（示例数据）。M4 接通协议后，把 kernel 对象转成
/// client_api 的 Chat / ChatMessage 注入即可，UI 层无需改动。
library;

import 'package:flutter/material.dart';

import '../../client_api/objects.dart';
import '../theme/telegram_theme.dart';
import '../widgets/message_bubble.dart';
import '../widgets/telegram_avatar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  int _selectedIndex = 0;
  bool _showChatList = true; // 窄屏时用于切换列表/对话

  static final _now = DateTime(2026, 9, 10, 18, 20);
  final List<Chat> _chats = [
    Chat(
      id: '1',
      title: '软件安全课程群',
      lastMessage: '老师：逆向作业下周交',
      lastTime: _now,
      unreadCount: 3,
      online: true,
    ),
    Chat(
      id: '2',
      title: '李老师',
      lastMessage: '记得把架构设计文档一起提交',
      lastTime: DateTime(2026, 9, 10, 17, 45),
      unreadCount: 1,
      online: true,
    ),
    Chat(
      id: '3',
      title: '室友·小王',
      lastMessage: '晚上一起吃饭？',
      lastTime: DateTime(2026, 9, 10, 16, 12),
    ),
    Chat(
      id: '4',
      title: '逆向学习小组',
      lastMessage: '[图片]',
      lastTime: DateTime(2026, 9, 9, 21, 30),
    ),
    Chat(
      id: '5',
      title: '文件传输助手',
      lastMessage: 'protocol-roadmap.md',
      lastTime: DateTime(2026, 9, 9, 15, 0),
    ),
  ];

  final List<ChatMessage> _messages = [
    ChatMessage(
      id: 'm1',
      text: '大家注意，本次作业要反编译官方的 APK，然后自己实现一个客户端',
      time: DateTime(2026, 9, 10, 18, 5),
      outgoing: false,
      senderName: '李老师',
    ),
    ChatMessage(
      id: 'm2',
      text: '收到，我先把协议层摸清楚',
      time: DateTime(2026, 9, 10, 18, 7),
      outgoing: true,
    ),
    ChatMessage(
      id: 'm3',
      text: '建议 UI 参考 Telegram 的分层设计，协议内核和界面解耦',
      time: DateTime(2026, 9, 10, 18, 12),
      outgoing: true,
    ),
    ChatMessage(
      id: 'm4',
      text: '对，内核用 Dart 先跑通，有余力再换 Rust 提升性能',
      time: DateTime(2026, 9, 10, 18, 20),
      outgoing: false,
      senderName: '李老师',
    ),
  ];

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(ChatMessage(
        id: 'm${_messages.length + 1}',
        text: text,
        time: DateTime.now(),
        outgoing: true,
      ));
    });
    _inputController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    if (wide) {
      return Scaffold(
        backgroundColor: TelegramColors.bgApp,
        body: Row(
          children: [
            SizedBox(width: TelegramMetrics.sidebarWidth, child: _buildSidebar()),
            Container(width: 1, color: TelegramColors.divider),
            Expanded(child: _buildChatPane()),
          ],
        ),
      );
    }
    // 窄屏（手机）：列表与对话二选一
    return Scaffold(
      backgroundColor: TelegramColors.bgApp,
      body: _showChatList
          ? _buildSidebar()
          : _buildChatPane(onBack: () => setState(() => _showChatList = true)),
    );
  }

  Widget _buildSidebar() {
    return Container(
      color: TelegramColors.bgSidebar,
      child: Column(
        children: [
          _buildSearchBar(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _chats.length,
              itemBuilder: (_, i) => _chatTile(_chats[i], i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: TelegramColors.bgHover,
          borderRadius: BorderRadius.circular(TelegramMetrics.inputRadius),
        ),
        child: const Row(
          children: [
            SizedBox(width: 14),
            Icon(Icons.search, size: 18, color: TelegramColors.textSecondary),
            SizedBox(width: 8),
            Text('搜索',
                style: TextStyle(
                    color: TelegramColors.textSecondary, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _chatTile(Chat chat, int index) {
    final selected = index == _selectedIndex;
    return InkWell(
      onTap: () => setState(() {
        _selectedIndex = index;
        _showChatList = false;
      }),
      child: Container(
        color: selected ? TelegramColors.bgSelected : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                TelegramAvatar(name: chat.title),
                if (chat.online)
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: TelegramColors.online,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: TelegramColors.bgSidebar, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TelegramColors.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chat.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TelegramColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  chat.lastTime == null ? '' : formatTime(chat.lastTime!),
                  style: const TextStyle(
                    color: TelegramColors.textSecondary,
                    fontSize: TelegramMetrics.fontTimestamp,
                  ),
                ),
                const SizedBox(height: 6),
                if (chat.unreadCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: TelegramColors.badge,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${chat.unreadCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatPane({VoidCallback? onBack}) {
    final chat = _chats[_selectedIndex];
    return Column(
      children: [
        _buildHeader(chat, onBack),
        Expanded(
          child: Container(
            color: TelegramColors.bgChat,
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: _messages.length,
              itemBuilder: (_, i) => MessageBubble(message: _messages[i]),
            ),
          ),
        ),
        _buildInputBar(),
      ],
    );
  }

  Widget _buildHeader(Chat chat, VoidCallback? onBack) {
    return Container(
      height: TelegramMetrics.headerHeight,
      color: TelegramColors.bgHeader,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back,
                  color: TelegramColors.textSecondary),
            ),
          TelegramAvatar(name: chat.title, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chat.title,
                  style: const TextStyle(
                    color: TelegramColors.textPrimary,
                    fontSize: TelegramMetrics.fontTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  chat.online ? '在线' : '离线',
                  style: TextStyle(
                    color: chat.online
                        ? TelegramColors.online
                        : TelegramColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.call, color: TelegramColors.textSecondary, size: 22),
          const SizedBox(width: 18),
          const Icon(Icons.more_vert,
              color: TelegramColors.textSecondary, size: 22),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      color: TelegramColors.bgInput,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const Icon(Icons.attach_file,
                color: TelegramColors.textSecondary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: TelegramColors.bgHover,
                  borderRadius:
                      BorderRadius.circular(TelegramMetrics.inputRadius),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _inputController,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(
                      color: TelegramColors.textPrimary, fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '输入消息…',
                    hintStyle:
                        TextStyle(color: TelegramColors.textSecondary),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: _send,
              child: Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: TelegramColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
