// Cab — ретро-чат у стилі Windows 98 (мобільний клієнт).
// Сервер: server.py (HTTP-опитування). Протокол такий самий, як у cab_chat.py.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ===== Налаштування =====

const serverUrl = 'https://yurist1606.pythonanywhere.com';
const maxNick = 20;
const maxText = 500;
const requestTimeout = 10; // секунд на запит
const pollFast = Duration(milliseconds: 1500);
const pollSlow = Duration(seconds: 4);
const slowAfterSeconds = 60;
const maxRetryDelay = 10.0;

// Кольори «Windows 98»
const face = Color(0xFFC0C0C0);
const teal = Color(0xFF008080);
const navy = Color(0xFF000080);
const grayText = Color(0xFF606060);
const darkGray = Color(0xFF404040);
const midGray = Color(0xFF808080);
const nickColors = <Color>[
  Color(0xFF000080), Color(0xFF008000), Color(0xFF800000), Color(0xFF800080),
  Color(0xFF008080), Color(0xFF808000), Color(0xFF0000FF), Color(0xFFFF0000),
];

const chatStyle = TextStyle(
  fontFamily: 'monospace', fontSize: 14, color: Colors.black,
);

Color nickColor(String name) =>
    nickColors[name.runes.fold<int>(0, (a, c) => a + c) % nickColors.length];

String? cleanNick(String? raw) {
  if (raw == null) return null;
  final noControl = raw.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '');
  final joined =
      noControl.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ');
  final cut = String.fromCharCodes(joined.runes.take(maxNick)).trim();
  return cut.isEmpty ? null : cut;
}

String randomNick() => 'Anonym${100 + Random().nextInt(900)}';

String hm(int? ts) {
  final t = ts == null
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

// ===== Мережа =====

class NetError implements Exception {
  final String message;
  NetError(this.message);
  @override
  String toString() => message;
}

class ApiResult {
  final int code;
  final Map<String, dynamic> data;
  ApiResult(this.code, this.data);
}

/// Працює у власному циклі; події віддає через onEvent (словники з ключем kind):
/// state, chat, users, rejoined, nick_taken, send_failed, error.
class CabClient {
  CabClient(String baseUrl, this.onEvent)
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;
  final void Function(Map<String, dynamic>) onEvent;

  int _gen = 0;
  final List<String> _outbox = [];
  Completer<void>? _wake;

  void start(String nick) {
    _gen++;
    _poke();
    _outbox.clear();
    _work(_gen, nick);
  }

  void stop() {
    _gen++;
    _poke();
  }

  void send(String text) {
    _outbox.add(text);
    _poke();
  }

  void wakeUp() => _poke();

  void _poke() {
    final c = _wake;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _sleep(Duration d) async {
    final c = Completer<void>();
    _wake = c;
    await Future.any([Future.delayed(d), c.future]);
    if (identical(_wake, c)) _wake = null;
  }

  void _emit(int run, Map<String, dynamic> data) {
    if (_gen == run) onEvent(data);
  }

  Future<ApiResult> _api(String action, Map<String, dynamic> payload,
      {int timeout = requestTimeout}) async {
    try {
      final r = await http
          .post(
            Uri.parse('$baseUrl/api/$action'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(Duration(seconds: timeout));
      var data = <String, dynamic>{};
      try {
        final d = jsonDecode(utf8.decode(r.bodyBytes));
        if (d is Map<String, dynamic>) data = d;
      } catch (_) {}
      return ApiResult(r.statusCode, data);
    } catch (e) {
      throw NetError(e.runtimeType.toString());
    }
  }

  Future<void> _work(int run, String nick) async {
    String? token;
    var since = 0;
    var state = 'connecting';
    var delay = 1.0;
    String? usersSeen;
    var lastActivity = DateTime.now();
    var joinedBefore = false;

    _emit(run, {'kind': 'state', 'state': 'connecting'});

    try {
      while (_gen == run) {
        try {
          // --- вхід ---
          if (token == null) {
            final r = await _api('join', {'nick': nick});
            if (_gen != run) return;
            if (r.code == 409) {
              _emit(run, {'kind': 'nick_taken'});
              return;
            }
            if (r.code != 200) {
              _emit(run, {
                'kind': 'error',
                'text': r.data['error'] == 'nick_invalid'
                    ? 'Сервер відхилив нікнейм.'
                    : 'Помилка сервера (${r.code}).',
              });
              return;
            }
            token = r.data['token'] as String;
            since = r.data['last'] as int;
            final users = List<dynamic>.from(r.data['users'] as List);
            usersSeen = jsonEncode(users);
            _emit(run, {'kind': 'users', 'users': users});
            if (joinedBefore) _emit(run, {'kind': 'rejoined'});
            joinedBefore = true;
          }

          if (state != 'online') {
            state = 'online';
            delay = 1.0;
            _emit(run, {'kind': 'state', 'state': 'online'});
          }

          // --- відправка ---
          while (_gen == run && _outbox.isNotEmpty) {
            final text = _outbox.removeAt(0);
            ApiResult r;
            try {
              r = await _api('send', {'token': token, 'text': text});
            } on NetError {
              _outbox.insert(0, text); // не губимо повідомлення
              rethrow;
            }
            if (r.code == 200) {
              lastActivity = DateTime.now();
            } else if (r.code == 401) {
              token = null;
              _outbox.insert(0, text); // надішлемо після нового входу
              break;
            } else {
              _emit(run, {'kind': 'send_failed', 'text': text});
            }
          }

          if (token == null) continue;

          // --- нові повідомлення ---
          final r = await _api('poll', {'token': token, 'since': since});
          if (_gen != run) return;
          if (r.code == 401) {
            token = null;
            continue;
          }
          if (r.code == 200) {
            since = (r.data['last'] as int?) ?? since;
            for (final e in (r.data['events'] as List? ?? const [])) {
              _emit(run, {'kind': 'chat', 'event': e});
              lastActivity = DateTime.now();
            }
            final users = List<dynamic>.from(r.data['users'] as List? ?? const []);
            final encoded = jsonEncode(users);
            if (encoded != usersSeen) {
              usersSeen = encoded;
              _emit(run, {'kind': 'users', 'users': users});
            }
          }

          final quiet = DateTime.now().difference(lastActivity).inSeconds;
          await _sleep(quiet < slowAfterSeconds ? pollFast : pollSlow);
        } on NetError catch (e) {
          if (state != 'offline') {
            state = 'offline';
            _emit(run, {'kind': 'state', 'state': 'offline', 'reason': e.message});
          }
          await _sleep(Duration(milliseconds: (delay * 1000).round()));
          delay = min(delay * 2, maxRetryDelay);
        }
      }
    } catch (e) {
      _emit(run, {'kind': 'error', 'text': 'Внутрішня помилка: $e'});
    } finally {
      if (token != null) {
        try {
          await _api('leave', {'token': token}, timeout: 3);
        } on NetError {
          // не критично
        }
      }
    }
  }
}

// ===== Оформлення в стилі 90-х =====

BoxDecoration bevel({bool sunken = false, Color fill = face}) {
  final light = sunken ? midGray : Colors.white;
  final dark = sunken ? Colors.white : darkGray;
  return BoxDecoration(
    color: fill,
    border: Border(
      top: BorderSide(color: light, width: 2),
      left: BorderSide(color: light, width: 2),
      bottom: BorderSide(color: dark, width: 2),
      right: BorderSide(color: dark, width: 2),
    ),
  );
}

class W98Button extends StatefulWidget {
  const W98Button({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<W98Button> createState() => _W98ButtonState();
}

class _W98ButtonState extends State<W98Button> {
  bool down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => down = true),
      onTapUp: (_) => setState(() => down = false),
      onTapCancel: () => setState(() => down = false),
      onTap: widget.onTap,
      child: Container(
        decoration: bevel(sunken: down),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(
          widget.label,
          style: const TextStyle(fontSize: 14, color: Colors.black),
        ),
      ),
    );
  }
}

class Line {
  Line({this.ts, this.nick, required this.text, this.system = false});
  final int? ts;
  final String? nick;
  final String text;
  final bool system;
}

// ===== Програма =====

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CabApp());
}

class CabApp extends StatelessWidget {
  const CabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: false,
        scaffoldBackgroundColor: teal,
        colorScheme: ColorScheme.fromSeed(seedColor: navy),
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  late final CabClient client;
  final lines = <Line>[];
  final entry = TextEditingController();
  final entryFocus = FocusNode();
  final scroll = ScrollController();

  String nick = '';
  bool online = false;
  bool wasOffline = false;
  List<String> users = [];
  String status = 'Підключення…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    client = CabClient(serverUrl, _onEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    client.stop();
    entry.dispose();
    entryFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Повернулися в застосунок — одразу питаємо нові повідомлення
    if (state == AppLifecycleState.resumed) client.wakeUp();
  }

  // --- запуск і нікнейм ---

  Future<void> _startup() async {
    final prefs = await SharedPreferences.getInstance();
    var n = cleanNick(prefs.getString('nick'));
    n ??= await _askNick('Введіть свій нікнейм:') ?? randomNick();
    _connect(n);
  }

  Future<String?> _askNick(String title) async {
    if (!mounted) return null;
    final c = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: face,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white, width: 2),
        ),
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: maxNick,
          decoration: const InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.zero),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Скасувати'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return cleanNick(result);
  }

  Future<void> _connect(String n) async {
    nick = n;
    online = false;
    SharedPreferences.getInstance().then((p) => p.setString('nick', n));
    _addSystem('Ласкаво просимо в Cab, $n!');
    setState(() => status = 'Підключення до сервера…');
    client.start(n);
  }

  Future<void> _changeNick() async {
    final n = await _askNick('Новий нікнейм:');
    if (n != null && n != nick) _connect(n);
  }

  // --- події від мережі ---

  void _onEvent(Map<String, dynamic> item) {
    if (!mounted) return;
    switch (item['kind']) {
      case 'state':
        _onState(item['state'] as String, (item['reason'] as String?) ?? '');
        break;
      case 'chat':
        _onChat(Map<String, dynamic>.from(item['event'] as Map));
        break;
      case 'users':
        setState(() => users = List<String>.from(
            (item['users'] as List).map((e) => e.toString())));
        break;
      case 'rejoined':
        _addSystem('Сеанс відновлено.');
        break;
      case 'nick_taken':
        _onNickTaken();
        break;
      case 'send_failed':
        _addSystem('Не вдалося надіслати повідомлення.');
        break;
      case 'error':
        _addSystem((item['text'] as String?) ?? 'Помилка.');
        break;
    }
  }

  void _onState(String state, String reason) {
    final host = Uri.parse(serverUrl).host;
    if (state == 'online') {
      setState(() {
        online = true;
        status = 'Підключено · $host';
      });
      if (wasOffline) {
        wasOffline = false;
        _addSystem("Зв'язок відновлено.");
      }
    } else if (state == 'offline') {
      setState(() {
        online = false;
        status = "Немає зв'язку · повторна спроба…";
      });
      if (!wasOffline) {
        wasOffline = true;
        final detail = reason.isEmpty ? '' : ' ($reason)';
        _addSystem("Немає зв'язку із сервером$detail. Повторюю спроби…");
      }
    } else {
      setState(() => status = 'Підключення до сервера…');
    }
  }

  void _onChat(Map<String, dynamic> e) {
    final ts = e['ts'] as int?;
    if (e['type'] == 'msg') {
      _add(Line(
        ts: ts,
        nick: (e['nick'] ?? '?').toString(),
        text: (e['text'] ?? '').toString(),
      ));
    } else {
      _addSystem((e['text'] ?? '').toString(), ts);
    }
  }

  Future<void> _onNickTaken() async {
    final n = await _askNick('Нік «$nick» уже зайнятий. Введіть інший:');
    _connect(n ?? randomNick());
  }

  // --- відображення ---

  void _addSystem(String text, [int? ts]) =>
      _add(Line(ts: ts, text: text, system: true));

  void _add(Line l) {
    final atBottom = !scroll.hasClients ||
        scroll.position.pixels >= scroll.position.maxScrollExtent - 24;
    setState(() {
      lines.add(l);
      if (lines.length > 1000) lines.removeRange(0, 200);
    });
    if (atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _send() {
    final text = entry.text.trim();
    if (text.isEmpty) return;
    if (!online) {
      setState(() => status = "Немає зв'язку: повідомлення не надіслано.");
      return;
    }
    client.send(text);
    entry.clear();
    entryFocus.requestFocus();
  }

  void _showUsers() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: face,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white, width: 2),
        ),
        title: const Text('У мережі', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final u in users)
                Text(
                  '• $u${u == nick ? '  (ви)' : ''}',
                  style: chatStyle.copyWith(color: nickColor(u)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: face,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white, width: 2),
        ),
        title: const Text('Про Cab', style: TextStyle(fontSize: 15)),
        content: Text(
          'Cab — ретро-чат у стилі 90-х.\n\nСервер: ${Uri.parse(serverUrl).host}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // --- інтерфейс ---

  Widget _titleBar() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF000080), Color(0xFF1084D0)],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.chat_bubble, color: Color(0xFFFFFF00), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              nick.isEmpty ? 'Cab — чат' : 'Cab — $nick',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
          PopupMenuButton<String>(
            color: face,
            shape: const RoundedRectangleBorder(),
            onSelected: (v) {
              if (v == 'nick') _changeNick();
              if (v == 'about') _showAbout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'nick', child: Text('Змінити нік…')),
              PopupMenuItem(value: 'about', child: Text('Про Cab')),
            ],
            child: Container(
              decoration: bevel(),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: const Text('≡', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineWidget(Line l) {
    final time = TextSpan(
      text: '[${hm(l.ts)}] ',
      style: const TextStyle(color: grayText),
    );
    final Widget content;
    if (l.system) {
      content = Text.rich(
        TextSpan(children: [
          time,
          TextSpan(
            text: '*** ${l.text} ***',
            style: const TextStyle(color: navy, fontStyle: FontStyle.italic),
          ),
        ]),
        style: chatStyle,
      );
    } else {
      content = Text.rich(
        TextSpan(children: [
          time,
          const TextSpan(text: '<'),
          TextSpan(
            text: l.nick,
            style: TextStyle(
              color: nickColor(l.nick ?? ''),
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(text: '> ${l.text}'),
        ]),
        style: chatStyle,
      );
    }
    return Padding(padding: const EdgeInsets.only(bottom: 3), child: content);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Container(
            decoration: bevel(),
            padding: const EdgeInsets.all(2),
            child: Column(
              children: [
                _titleBar(),
                const SizedBox(height: 4),
                Expanded(
                  child: Container(
                    decoration: bevel(sunken: true, fill: Colors.white),
                    child: ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.all(6),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => _lineWidget(lines[i]),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: bevel(sunken: true, fill: Colors.white),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: TextField(
                          controller: entry,
                          focusNode: entryFocus,
                          style: chatStyle,
                          textInputAction: TextInputAction.send,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(maxText),
                          ],
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Повідомлення…',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    W98Button(label: 'Надіслати', onTap: _send),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: bevel(sunken: true),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        child: Text(
                          status,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    GestureDetector(
                      onTap: _showUsers,
                      child: Container(
                        decoration: bevel(sunken: true),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        child: Text(
                          'Людей: ${users.length}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
