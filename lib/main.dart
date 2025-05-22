import 'dart:async'; // For StreamSubscription
import 'dart:convert'; // 用于 JSON 编解码
import 'dart:io'; // 用于 HttpClient (代理设置) 和文件操作
import 'dart:math'; // For min/max
import 'dart:typed_data'; // 用于 Uint8List (音频字节)
import 'dart:ui'; // For ImageFilter.blur

import 'package:flutter/foundation.dart'; // For compute
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart'; // 文件选择器
import 'package:http/http.dart' as http; // HTTP 客户端
import 'package:http/io_client.dart'; // 用于带自定义 HttpClient 的 IOClient (代理)
import 'package:just_audio/just_audio.dart' as ja; // just_audio 播放器, 使用别名 ja
import 'package:audioplayers/audioplayers.dart'
    as ap; // audioplayers 播放器, 使用别名 ap
import 'package:path_provider/path_provider.dart'; // For temporary file storage

import 'package:flutter_secure_storage/flutter_secure_storage.dart'; // 安全存储
import 'package:shared_preferences/shared_preferences.dart'; // 偏好设置存储
import 'package:intl/intl.dart'; // For date formatting in logs
import 'package:epub_parser/epub_parser.dart';
// import 'package:gbk_codec/gbk_codec.dart'; // Only if GBK support for TXT is re-added

// TTS Provider Enum
enum TTSProvider { openai, microsoft }

// Data class for Windows preloaded chunks
class WindowsPreloadedChunk {
  final int originalChunkIndex;
  final String filePath;
  final String text; // Keep the text for display purposes if needed

  WindowsPreloadedChunk({
    required this.originalChunkIndex,
    required this.filePath,
    required this.text,
  });
}

// 辅助类：用于 just_audio 从内存字节流播放音频
class BytesAudioSource extends ja.StreamAudioSource {
  final Uint8List _bytes;
  final String _contentType;

  BytesAudioSource(this._bytes, {String contentType = 'audio/mpeg'})
    : _contentType = contentType,
      super(tag: 'BytesAudioSource');

  @override
  Future<ja.StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    final clippedBytes = _bytes.sublist(start, end);

    return ja.StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: clippedBytes.length,
      offset: start,
      stream: Stream.value(clippedBytes),
      contentType: _contentType,
    );
  }
}

// Helper structure for retry result
enum RetryStatus { success, failedAndUserCancelled, failedAfterMaxRetries }

class FetchAttemptResult {
  final Uint8List? audioBytes;
  final RetryStatus status;

  FetchAttemptResult(this.audioBytes, this.status);
}

// Reading Theme Data Class
class ReadingTheme {
  final Color backgroundColor;
  final Color textColor;
  final Color playingChunkTextColor;
  final Color karaokeFillColor;
  final Color karaokeTextColor;
  final bool applyBlur;

  ReadingTheme({
    required this.backgroundColor,
    required this.textColor,
    required this.playingChunkTextColor,
    required this.karaokeFillColor,
    required this.karaokeTextColor,
    this.applyBlur = false,
  });

  Map<String, String> toJson() => {
    'backgroundColor': backgroundColor.value.toRadixString(16),
    'textColor': textColor.value.toRadixString(16),
    'playingChunkTextColor': playingChunkTextColor.value.toRadixString(16),
    'karaokeFillColor': karaokeFillColor.value.toRadixString(16),
    'karaokeTextColor': karaokeTextColor.value.toRadixString(16),
    'applyBlur': applyBlur.toString(),
  };

  factory ReadingTheme.fromJson(Map<String, dynamic> json) {
    return ReadingTheme(
      backgroundColor: Color(
        int.parse(
          json['backgroundColor'] ??
              _defaultReadingTheme.backgroundColor.value.toRadixString(16),
          radix: 16,
        ),
      ),
      textColor: Color(
        int.parse(
          json['textColor'] ??
              _defaultReadingTheme.textColor.value.toRadixString(16),
          radix: 16,
        ),
      ),
      playingChunkTextColor: Color(
        int.parse(
          json['playingChunkTextColor'] ??
              _defaultReadingTheme.playingChunkTextColor.value.toRadixString(
                16,
              ),
          radix: 16,
        ),
      ),
      karaokeFillColor: Color(
        int.parse(
          json['karaokeFillColor'] ??
              _defaultReadingTheme.karaokeFillColor.value.toRadixString(16),
          radix: 16,
        ),
      ),
      karaokeTextColor: Color(
        int.parse(
          json['karaokeTextColor'] ??
              _defaultReadingTheme.karaokeTextColor.value.toRadixString(16),
          radix: 16,
        ),
      ),
      applyBlur: (json['applyBlur'] ?? 'false') == 'true',
    );
  }
}

final ReadingTheme _defaultReadingTheme =
    _predefinedThemes['毛玻璃 (Frosted Glass)']!; // Default to Frosted Glass

final Map<String, ReadingTheme> _predefinedThemes = {
  '默认 (Default)': ReadingTheme(
    // Original Default
    backgroundColor: const Color(0xFFF5F5DC),
    textColor: Colors.black87,
    playingChunkTextColor: Colors.deepPurpleAccent,
    karaokeFillColor: Colors.yellow.withOpacity(0.4),
    karaokeTextColor: Colors.redAccent[700]!,
  ),
  '米黄 (Beige)': ReadingTheme(
    backgroundColor: const Color(0xFFF5F5DC),
    textColor: Colors.black87,
    playingChunkTextColor: Colors.brown,
    karaokeFillColor: Colors.orange.withOpacity(0.3),
    karaokeTextColor: Colors.deepOrange,
  ),
  '浅绿 (Mint Green)': ReadingTheme(
    backgroundColor: const Color(0xFFE0F2F1),
    textColor: Colors.teal[900]!,
    playingChunkTextColor: Colors.teal[700]!,
    karaokeFillColor: Colors.greenAccent.withOpacity(0.4),
    karaokeTextColor: Colors.green[800]!,
  ),
  '夜间 (Night)': ReadingTheme(
    backgroundColor: Colors.grey[850]!,
    textColor: Colors.grey[300]!,
    playingChunkTextColor: Colors.cyanAccent,
    karaokeFillColor: Colors.blueGrey.withOpacity(0.5),
    karaokeTextColor: Colors.lightBlueAccent,
  ),
  'E-ink (墨水屏)': ReadingTheme(
    backgroundColor: Colors.grey[100]!,
    textColor: Colors.black.withOpacity(0.8),
    playingChunkTextColor: Colors.blueGrey[700]!,
    karaokeFillColor: Colors.grey[300]!.withOpacity(0.5),
    karaokeTextColor: Colors.black,
  ),
  '毛玻璃 (Frosted Glass)': ReadingTheme(
    backgroundColor: Colors.white.withOpacity(0.65),
    textColor: Colors.black87,
    playingChunkTextColor: Colors.blue[800]!,
    karaokeFillColor: Colors.lightBlueAccent.withOpacity(0.4),
    karaokeTextColor: Colors.blue[900]!,
    applyBlur: true,
  ),
};

// Top-level function for decoding file in an isolate
Future<String> _readFileContentInBackground(Map<String, dynamic> params) async {
  final String filePath = params['filePath'];
  final File file = File(filePath);
  final String lowerCaseFilePath = filePath.toLowerCase();

  if (lowerCaseFilePath.endsWith('.epub')) {
    try {
      EpubBook epubBook = await EpubReader.readBook(file.readAsBytesSync());
      StringBuffer sb = StringBuffer();

      if (epubBook.Content?.Html != null &&
          epubBook.Content!.Html!.isNotEmpty) {
        for (var htmlFile in epubBook.Content!.Html!.values) {
          if (htmlFile.Content != null) {
            String plainText =
                htmlFile.Content!
                    .replaceAll(RegExp(r'<[^>]*>'), ' ')
                    .replaceAll(RegExp(r'\s+'), ' ')
                    .trim();
            sb.writeln(plainText);
            sb.writeln();
          }
        }
      } else if (epubBook.Chapters != null && epubBook.Chapters!.isNotEmpty) {
        for (var chapter in epubBook.Chapters!) {
          if (chapter.HtmlContent != null) {
            String plainText =
                chapter.HtmlContent!
                    .replaceAll(RegExp(r'<[^>]*>'), ' ')
                    .replaceAll(RegExp(r'\s+'), ' ')
                    .trim();
            sb.writeln(plainText);
            sb.writeln();
          }
        }
      }

      if (sb.isEmpty) {
        return "未能从 EPUB 文件中提取文本内容。(Could not extract text content from EPUB file.)";
      }
      return sb.toString();
    } catch (e) {
      debugPrint("EPUB parsing failed for $filePath. Error: $e");
      return "EPUB 文件解析失败: $e (EPUB file parsing failed: $e)";
    }
  } else if (lowerCaseFilePath.endsWith('.mobi') ||
      lowerCaseFilePath.endsWith('.azw3')) {
    return "不支持直接读取 MOBI/AZW3 文件内容。\n请先将文件转换为 EPUB 或 TXT 格式。\n(Direct reading of MOBI/AZW3 content is not supported. Please convert to EPUB or TXT first.)";
  } else {
    // For TXT files, assume UTF-8
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes, allowMalformed: false); // Strict UTF-8 decoding
    } catch (e) {
      debugPrint(
        "UTF-8 decoding failed for $filePath (strict), trying with allowMalformed. Error: $e",
      );
      try {
        return utf8.decode(bytes, allowMalformed: true);
      } catch (e2) {
        debugPrint(
          "UTF-8 decoding with allowMalformed also failed for $filePath. Error: $e2",
        );
        return "无法以UTF-8解码文件: $e2 (Failed to decode file as UTF-8)";
      }
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenAI TTS 朗读器',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurpleAccent),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurpleAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const MyHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _mainTextHolderController = TextEditingController();
  final _displayAreaScrollController = ScrollController();

  final _secureStorage = const FlutterSecureStorage();
  late SharedPreferences _prefs;

  TTSProvider _selectedTTSProvider = TTSProvider.openai;

  String _apiKey = '';
  String _selectedModel = _MyHomePageState._defaultOpenAIModelSettings;
  String _selectedVoice = _MyHomePageState._defaultOpenAIVoiceSettings;

  String _msSubscriptionKey = '';
  String _msRegion = _MyHomePageState._defaultMsRegionSettings;
  String _msSelectedLanguage = _MyHomePageState._defaultMsLanguage;
  String _msSelectedVoiceName = '';
  Map<String, List<String>> _dynamicMsVoicesByLanguage = {};
  bool _isFetchingMsVoices = false;

  bool _isLoading = false;
  String? _currentlyFetchingChunkText;
  bool _isBufferingInBackground = false;
  String? _backgroundBufferingPreviewText;
  bool _useProxy = _MyHomePageState._defaultUseProxySettings;
  String _proxyHost = _MyHomePageState._defaultProxyHostSettings;
  String _proxyPort = _MyHomePageState._defaultProxyPortSettings;
  double _playbackSpeed = _MyHomePageState._defaultPlaybackSpeedSettings;
  ReadingTheme _currentReadingTheme = _defaultReadingTheme;
  Locale _selectedLocale = const Locale('zh');
  double _volume = _MyHomePageState._defaultVolumeSettings;

  final ja.AudioPlayer _justAudioPlayer = ja.AudioPlayer();
  final ap.AudioPlayer _windowsAudioPlayer = ap.AudioPlayer();
  StreamSubscription? _windowsPlayerCompleteSubscription;
  StreamSubscription? _windowsPlayerStateSubscription;
  StreamSubscription? _windowsPlayerPositionSubscription;
  final List<WindowsPreloadedChunk> _windowsPreloadedChunks = [];

  // AnimationController? _leftFabAnimationController; // Removed
  // Animation<double>? _leftFabOpacityAnimation; // Removed
  // Animation<Offset>? _leftFabSlideAnimation; // Removed

  // AnimationController? _rightFabAnimationController; // Removed
  // Animation<double>? _rightFabOpacityAnimation; // Removed
  // Animation<Offset>? _rightFabSlideAnimation; // Removed
  // Timer? _fabHideTimer; // Removed

  static const String _defaultOpenAIModelSettings = 'tts-1';
  static const String _defaultOpenAIVoiceSettings = 'nova';
  static const String _defaultMsRegionSettings = 'westus';
  static const String _defaultMsLanguage = 'zh-CN';
  static const bool _defaultUseProxySettings = false;
  static const String _defaultProxyHostSettings = '127.0.0.1';
  static const String _defaultProxyPortSettings = '7897';
  static const double _defaultPlaybackSpeedSettings = 1.0;
  static const double _defaultVolumeSettings = 1.0; // Default volume
  static const double _minPlaybackSpeed = 0.25;
  static const double _maxPlaybackSpeed = 5.0;
  static const int _defaultMaxCharsPerRequestSettings = 300;
  static const int _defaultPrefetchChunkCountSettings = 2;

  final List<String> _openAIModels = ['tts-1', 'tts-1-hd'];
  final List<String> _openAIVoices = [
    'alloy',
    'echo',
    'fable',
    'onyx',
    'nova',
    'shimmer',
  ];
  final Map<String, List<String>> _msHardcodedVoicesByLanguage = {
    'zh-CN': [
      'zh-CN-XiaoxiaoNeural',
      'zh-CN-YunyangNeural',
      'zh-CN-XiaoyiNeural',
      'zh-CN-YunjianNeural',
      'zh-CN-YunxiNeural',
      'zh-CN-YunyeNeural',
    ],
    'en-US': [
      'en-US-JennyNeural',
      'en-US-AriaNeural',
      'en-US-GuyNeural',
      'en-US-DavisNeural',
      'en-US-JaneNeural',
    ],
    'ja-JP': ['ja-JP-NanamiNeural', 'ja-JP-KeitaNeural'],
    'ko-KR': ['ko-KR-SunHiNeural', 'ko-KR-InJoonNeural'],
  };

  int _maxCharsPerRequest = _MyHomePageState._defaultMaxCharsPerRequestSettings;
  int _prefetchChunkCount = _MyHomePageState._defaultPrefetchChunkCountSettings;

  String _currentTextForDisplay = "";
  List<Map<String, dynamic>> _processedTextChunks = [];
  List<GlobalKey> _chunkKeys = [];
  int _currentlyPlayingChunkIndex = -1;
  int _highlightedCharacterInChunkIndex = -1;

  int _currentChunkIndexToFetch = 0;
  final int _refetchThreshold = 1;
  bool _isFetchingMore = false;
  ja.ConcatenatingAudioSource? _playlist;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  List<int> _bookmarks = [];

  static const String _profilesKey = 'tts_app_profiles_map';
  Map<String, String> _savedProfiles = {};

  List<String> _errorLogs = [];
  static const String _errorLogsKey = 'tts_app_error_logs';
  static const int _maxLogEntries = 100;

  int? _lastPlayedTextContentHash;
  int? _lastPlayedChunkStartIndex;
  int? _lastPlayedPositionMillis;
  bool _resumePromptShownThisSession = false;

  final Map<String, Map<String, String>> _localizedStrings = {
    'zh': {
      'settingsTitle': '设置',
      'readAloudButton': '朗读文本',
      'cancelLoadingButton': '取消加载',
      'pauseButton': '暂停',
      'stopButton': '停止',
      'resumeButton': '继续',
      'inputTextButton': '输入或加载文本',
      'bookmarksButton': '书签',
      'playbackSpeedButton': '播放倍速',
      'volumeButton': '音量', // New
      'settingsButton': '设置',
      'inputDialogTitle': '输入或加载文本',
      'inputDialogLabel': '在此输入文本',
      'inputDialogHint': '输入或粘贴文本内容...',
      'loadFromFileButton': '从文件加载',
      'applyTextButton': '应用文本',
      'cancelButton': '取消',
      'noBookmarks': '暂无书签。',
      'bookmarksDialogTitle': '书签',
      'deleteBookmarkTooltip': '删除书签',
      'noBookmarksForText': '没有找到对应文本的书签。',
      'closeButton': '关闭',
      'playbackSpeedDialogTitle': '设置播放倍速',
      'volumeDialogTitle': '设置音量', // New
      'currentSpeedLabel': '当前倍速',
      'currentVolumeLabel': '当前音量', // New
      'applyButton': '应用',
      'ttsProviderLabel': 'TTS 服务提供商',
      'openAIApiKeyLabel': 'OpenAI API Key',
      'openAIApiKeyHint': 'sk-xxxxxxxxxx',
      'openAIModelLabel': 'OpenAI TTS 模型',
      'openAIVoiceLabel': 'OpenAI TTS 语音',
      'testOpenAIConfigButton': '检测 OpenAI 配置',
      'msSubKeyLabel': 'Microsoft 订阅密钥',
      'msRegionLabel': 'Microsoft 服务区域',
      'msRegionHint': '例如: eastus, westus2',
      'msLanguageLabel': 'Microsoft TTS 语言',
      'refreshVoiceListTooltip': '刷新语音列表',
      'msVoiceNameLabel': 'Microsoft TTS 语音名称',
      'msVoiceNotAvailable': '请先选择语言并刷新语音列表。',
      'testMSConfigButton': '检测 Microsoft 配置',
      'maxCharsLabel': '最大请求字符数',
      'maxCharsHint': '例如: 4000',
      'prefetchChunksLabel': '预加载片段数',
      'prefetchChunksHint': '例如: 2',
      'useProxyLabel': '使用 HTTP 代理',
      'proxyHostLabel': '代理服务器地址',
      'proxyPortLabel': '代理服务器端口',
      'readingThemeLabel': '阅读主题',
      'selectPresetThemeLabel': '选择预设主题',
      'saveCurrentConfigButton': '保存当前配置',
      'loadManageConfigButton': '加载/管理配置',
      'viewClearLogsButton': '查看/清除日志',
      'resetActiveSettingsButton': '重置活动设置',
      'interfaceLanguageLabel': '界面语言',
      'errorLogsTitle': '错误日志',
      'noLogs': '暂无日志。',
      'clearLogsButton': '清除日志',
      'saveProfileTitle': '保存配置',
      'profileNameHint': '输入配置文件名称',
      'saveButton': '保存',
      'loadProfileTitle': '加载/管理配置',
      'noSavedProfiles': '没有已保存的配置。',
      'exportProfileTooltip': '导出配置',
      'loadProfileTooltip': '加载',
      'deleteProfileTooltip': '删除',
      'importProfileButton': '导入配置文件',
      'nameThisProfileLabel': '为此配置命名',
      'importButton': '导入',
      'confirmOverwriteTitle': '确认覆盖',
      'confirmOverwriteMessage': '配置文件 "{profileName}" 已存在。要覆盖它吗？',
      'yesButton': '是',
      'noButton': '否',
      'confirmDeleteTitle': '确认删除',
      'confirmDeleteMessage': '确定要删除配置 "{profileName}" 吗？此操作无法撤销。',
      'deleteButton': '删除',
      'chunkLabel': '片段',
      'speedLabel': '倍速',
      'bufferingLabel': '缓冲',
      'loadingLabel': '正在加载',
      'resumePromptMessage': '是否从上次的进度继续朗读？',
    },
    'en': {
      'settingsTitle': 'Settings',
      'readAloudButton': 'Read Aloud',
      'cancelLoadingButton': 'Cancel Loading',
      'pauseButton': 'Pause',
      'stopButton': 'Stop',
      'resumeButton': 'Resume',
      'inputTextButton': 'Input or Load Text',
      'bookmarksButton': 'Bookmarks',
      'playbackSpeedButton': 'Playback Speed',
      'volumeButton': 'Volume', // New
      'settingsButton': 'Settings',
      'inputDialogTitle': 'Input or Load Text',
      'inputDialogLabel': 'Enter text here',
      'inputDialogHint': 'Type or paste text content...',
      'loadFromFileButton': 'Load from File',
      'applyTextButton': 'Apply Text',
      'cancelButton': 'Cancel',
      'noBookmarks': 'No bookmarks yet.',
      'bookmarksDialogTitle': 'Bookmarks',
      'deleteBookmarkTooltip': 'Delete Bookmark',
      'noBookmarksForText': 'No bookmarks found for current text.',
      'closeButton': 'Close',
      'playbackSpeedDialogTitle': 'Set Playback Speed',
      'volumeDialogTitle': 'Set Volume', // New
      'currentSpeedLabel': 'Current Speed',
      'currentVolumeLabel': 'Current Volume', // New
      'applyButton': 'Apply',
      'ttsProviderLabel': 'TTS Provider',
      'openAIApiKeyLabel': 'OpenAI API Key',
      'openAIApiKeyHint': 'sk-xxxxxxxxxx',
      'openAIModelLabel': 'OpenAI TTS Model',
      'openAIVoiceLabel': 'OpenAI TTS Voice',
      'testOpenAIConfigButton': 'Test OpenAI Config',
      'msSubKeyLabel': 'Microsoft Subscription Key',
      'msRegionLabel': 'Microsoft Service Region',
      'msRegionHint': 'e.g.: eastus, westus2',
      'msLanguageLabel': 'Microsoft TTS Language',
      'refreshVoiceListTooltip': 'Refresh Voice List',
      'msVoiceNameLabel': 'Microsoft TTS Voice Name',
      'msVoiceNotAvailable': 'Please select language and refresh voice list.',
      'testMSConfigButton': 'Test Microsoft Config',
      'maxCharsLabel': 'Max Chars/Request',
      'maxCharsHint': 'e.g.: 4000',
      'prefetchChunksLabel': 'Prefetch Chunks',
      'prefetchChunksHint': 'e.g.: 2',
      'useProxyLabel': 'Use HTTP Proxy',
      'proxyHostLabel': 'Proxy Host',
      'proxyPortLabel': 'Proxy Port',
      'readingThemeLabel': 'Reading Theme',
      'selectPresetThemeLabel': 'Select Preset Theme',
      'saveCurrentConfigButton': 'Save Current Configuration',
      'loadManageConfigButton': 'Load/Manage Configurations',
      'viewClearLogsButton': 'View/Clear Logs',
      'resetActiveSettingsButton': 'Reset Active Settings',
      'interfaceLanguageLabel': 'Interface Language',
      'errorLogsTitle': 'Error Logs',
      'noLogs': 'No logs yet.',
      'clearLogsButton': 'Clear Logs',
      'saveProfileTitle': 'Save Configuration',
      'profileNameHint': 'Enter profile name',
      'saveButton': 'Save',
      'loadProfileTitle': 'Load/Manage Configurations',
      'noSavedProfiles': 'No saved profiles.',
      'exportProfileTooltip': 'Export Profile',
      'loadProfileTooltip': 'Load',
      'deleteProfileTooltip': 'Delete',
      'importProfileButton': 'Import Profile',
      'nameThisProfileLabel': 'Name this profile',
      'importButton': 'Import',
      'confirmOverwriteTitle': 'Confirm Overwrite',
      'confirmOverwriteMessage':
          'Profile "{profileName}" already exists. Overwrite it?',
      'yesButton': 'Yes',
      'noButton': 'No',
      'confirmDeleteTitle': 'Confirm Delete',
      'confirmDeleteMessage':
          'Are you sure you want to delete profile "{profileName}"? This action cannot be undone.',
      'deleteButton': 'Delete',
      'chunkLabel': 'Chunk',
      'speedLabel': 'Speed',
      'bufferingLabel': 'Buffering',
      'loadingLabel': 'Loading',
      'resumePromptMessage': 'Resume from last position?',
    },
  };

  String _tr(String key, {Map<String, String>? params}) {
    String? translated =
        _localizedStrings[_selectedLocale.languageCode]?[key] ??
        _localizedStrings['zh']?[key];
    if (translated == null) return key; // Fallback to key if no translation
    if (params != null) {
      params.forEach((paramKey, value) {
        translated = translated!.replaceAll('{$paramKey}', value);
      });
    }
    return translated!;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettingsAndProfiles();

    // FAB animations are removed
    // _leftFabAnimationController = AnimationController(
    //   vsync: this,
    //   duration: const Duration(milliseconds: 300),
    // );
    // _leftFabOpacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
    //   CurvedAnimation(parent: _leftFabAnimationController!, curve: Curves.easeOut),
    // );
    // _leftFabSlideAnimation = Tween<Offset>(begin: Offset.zero, end: const Offset(-1.5, 0.0))
    //     .animate(CurvedAnimation(parent: _leftFabAnimationController!, curve: Curves.easeOut));

    // _rightFabAnimationController = AnimationController(
    //   vsync: this,
    //   duration: const Duration(milliseconds: 300),
    // );
    // _rightFabOpacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
    //   CurvedAnimation(parent: _rightFabAnimationController!, curve: Curves.easeOut),
    // );
    // _rightFabSlideAnimation = Tween<Offset>(begin: Offset.zero, end: const Offset(1.5, 0.0))
    //     .animate(CurvedAnimation(parent: _rightFabAnimationController!, curve: Curves.easeOut));

    // Listener for just_audio (non-Windows)
    _justAudioPlayer.playerStateStream.listen((playerState) {
      if (Platform.isWindows) return;
      // _updateFabVisibilityBasedOnPlayback(); // Removed
      if (mounted) {
        final processingState = playerState.processingState;
        if ((processingState == ja.ProcessingState.idle &&
                !playerState.playing) ||
            processingState == ja.ProcessingState.completed) {
          if (_isLoading) {
            setState(() {
              _isLoading = false;
              _currentlyFetchingChunkText = null;
            });
          }
          if (_currentlyPlayingChunkIndex != -1 &&
              _processedTextChunks.isNotEmpty &&
              _currentlyPlayingChunkIndex < _processedTextChunks.length) {
            _saveCurrentPlaybackProgress(
              _currentlyPlayingChunkIndex,
              _justAudioPlayer.duration ?? Duration.zero,
            );
            // _toggleBookmark( // Removed auto-bookmarking
            //   _processedTextChunks[_currentlyPlayingChunkIndex]['startIndex']
            //       as int,
            //   autoAddOnly: true,
            // );
            setState(() {
              _currentlyPlayingChunkIndex = -1;
              _highlightedCharacterInChunkIndex = -1;
            });
          }
        } else if (playerState.playing == false &&
            processingState == ja.ProcessingState.ready) {
          if (_currentlyPlayingChunkIndex != -1 &&
              _processedTextChunks.isNotEmpty &&
              _currentlyPlayingChunkIndex < _processedTextChunks.length) {
            _saveCurrentPlaybackProgress(
              _currentlyPlayingChunkIndex,
              _justAudioPlayer.position,
            );
          }
        }
        if (mounted && !_isLoading) {
          setState(() {});
        }
      }
    });

    _positionSubscription = _justAudioPlayer.positionStream.listen((position) {
      if (Platform.isWindows) return;
      if (!mounted ||
          _currentlyPlayingChunkIndex < 0 ||
          _currentlyPlayingChunkIndex >= _processedTextChunks.length) {
        return;
      }
      final currentChunkData =
          _processedTextChunks[_currentlyPlayingChunkIndex];
      final chunkText = currentChunkData['text'] as String?;
      final chunkDurationMillis = currentChunkData['durationMillis'] as int?;

      if (chunkText != null &&
          chunkText.isNotEmpty &&
          chunkDurationMillis != null &&
          chunkDurationMillis > 0) {
        double progressRatio = position.inMilliseconds / chunkDurationMillis;
        progressRatio = progressRatio.clamp(0.0, 1.0);
        int newCharIndex = (progressRatio * chunkText.length).floor();
        newCharIndex = newCharIndex.clamp(0, chunkText.length - 1);
        if (newCharIndex != _highlightedCharacterInChunkIndex) {
          setState(() => _highlightedCharacterInChunkIndex = newCharIndex);
        }
      }
    });

    // Listeners for audioplayers (Windows)
    _windowsPlayerStateSubscription = _windowsAudioPlayer.onPlayerStateChanged
        .listen((ap.PlayerState s) {
          if (!Platform.isWindows || !mounted) return;
          // _updateFabVisibilityBasedOnPlayback(); // Removed
          setState(() {
            // Potentially update UI based on _windowsAudioPlayer.state
          });
        });
    _windowsPlayerCompleteSubscription = _windowsAudioPlayer.onPlayerComplete
        .listen((event) async {
          if (!Platform.isWindows || !mounted) return;

          WindowsPreloadedChunk? playedChunkData;
          if (_windowsPreloadedChunks.isNotEmpty &&
              _currentlyPlayingChunkIndex ==
                  _windowsPreloadedChunks.first.originalChunkIndex) {
            playedChunkData = _windowsPreloadedChunks.removeAt(0);
            try {
              final file = File(playedChunkData.filePath);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (e) {
              _addErrorLog(
                "Error deleting temp file ${playedChunkData.filePath}: $e",
              );
            }
          }

          if (_currentlyPlayingChunkIndex != -1 &&
              _processedTextChunks.isNotEmpty &&
              _currentlyPlayingChunkIndex < _processedTextChunks.length) {
            _saveCurrentPlaybackProgress(
              _currentlyPlayingChunkIndex,
              Duration.zero,
            );
          }

          int nextChunkToPlayInProcessedList = _currentlyPlayingChunkIndex + 1;

          if (_windowsPreloadedChunks.isNotEmpty &&
              _windowsPreloadedChunks.first.originalChunkIndex ==
                  nextChunkToPlayInProcessedList) {
            await _startWindowsPlaybackFromQueue();
          } else if (nextChunkToPlayInProcessedList <
              _processedTextChunks.length) {
            await _initiatePlaybackFromIndex(nextChunkToPlayInProcessedList);
          } else {
            setState(() {
              _currentlyPlayingChunkIndex = -1;
              _highlightedCharacterInChunkIndex = -1;
              _isLoading = false;
            });
            // _showFabs(); // Removed
          }
          if (_windowsPreloadedChunks.length < _prefetchChunkCount &&
              _currentChunkIndexToFetch < _processedTextChunks.length) {
            _preloadNextWindowsChunk();
          }
        });
    _windowsPlayerPositionSubscription = _windowsAudioPlayer.onPositionChanged
        .listen((Duration p) {
          if (!Platform.isWindows ||
              !mounted ||
              _currentlyPlayingChunkIndex < 0 ||
              _currentlyPlayingChunkIndex >= _processedTextChunks.length)
            return;

          final currentChunkData =
              _processedTextChunks[_currentlyPlayingChunkIndex];
          final chunkText = currentChunkData['text'] as String?;
          _windowsAudioPlayer.getDuration().then((d) {
            if (d != null &&
                chunkText != null &&
                chunkText.isNotEmpty &&
                d.inMilliseconds > 0) {
              double progressRatio = p.inMilliseconds / d.inMilliseconds;
              progressRatio = progressRatio.clamp(0.0, 1.0);
              int newCharIndex = (progressRatio * chunkText.length).floor();
              newCharIndex = newCharIndex.clamp(0, chunkText.length - 1);
              if (newCharIndex != _highlightedCharacterInChunkIndex) {
                setState(
                  () => _highlightedCharacterInChunkIndex = newCharIndex,
                );
              }
            }
          });
        });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mainTextHolderController.dispose();
    _displayAreaScrollController.dispose();
    _currentIndexSubscription?.cancel();
    _positionSubscription?.cancel();
    _justAudioPlayer.dispose();
    _windowsAudioPlayer.dispose();
    _windowsPlayerCompleteSubscription?.cancel();
    _windowsPlayerStateSubscription?.cancel();
    _windowsPlayerPositionSubscription?.cancel();
    // _leftFabAnimationController?.dispose(); // Removed
    // _rightFabAnimationController?.dispose(); // Removed
    // _fabHideTimer?.cancel(); // Removed
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_currentlyPlayingChunkIndex != -1 &&
          _processedTextChunks.isNotEmpty &&
          _currentlyPlayingChunkIndex < _processedTextChunks.length) {
        Duration currentPosition = Duration.zero;
        if (Platform.isWindows) {
          // Handled by onPlayerComplete or stop for Windows
        } else {
          currentPosition = _justAudioPlayer.position;
        }
        _saveCurrentPlaybackProgress(
          _currentlyPlayingChunkIndex,
          currentPosition,
        );
        // _toggleBookmark( // Removed auto-bookmarking
        //   _processedTextChunks[_currentlyPlayingChunkIndex]['startIndex']
        //       as int,
        //   autoAddOnly: true,
        // );
      }
    }
  }

  bool _isCurrentlyPlaying() {
    if (Platform.isWindows) {
      return _windowsAudioPlayer.state == ap.PlayerState.playing;
    } else {
      return _justAudioPlayer.playing;
    }
  }

  // void _updateFabVisibilityBasedOnPlayback() { // Removed
  //   if (_isCurrentlyPlaying()) {
  //     _hideFabsWithDelay();
  //   } else {
  //     _showFabs();
  //   }
  // }

  // void _showFabs() { // Removed
  //   _fabHideTimer?.cancel();
  //   _leftFabAnimationController?.reverse();
  //   _rightFabAnimationController?.reverse();
  // }

  // void _hideFabs() { // Removed
  //   _fabHideTimer?.cancel();
  //   _leftFabAnimationController?.forward();
  //   _rightFabAnimationController?.forward();
  // }

  // void _hideFabsWithDelay() { // Removed
  //   _fabHideTimer?.cancel();
  //   _fabHideTimer = Timer(const Duration(seconds: 2), () {
  //     if (_isCurrentlyPlaying() && mounted) {
  //         _hideFabs();
  //     }
  //   });
  // }

  Future<void> _loadSettingsAndProfiles() async {
    _prefs = await SharedPreferences.getInstance();
    _apiKey = await _secureStorage.read(key: 'openai_api_key') ?? '';
    _msSubscriptionKey = await _secureStorage.read(key: 'ms_tts_key') ?? '';

    _mainTextHolderController.text =
        _prefs.getString('main_text_content') ?? '';
    List<String>? savedBookmarksString = _prefs.getStringList('bookmarks_list');
    if (savedBookmarksString != null) {
      _bookmarks =
          savedBookmarksString
              .map((s) => int.tryParse(s) ?? -1)
              .where((i) => i != -1)
              .toList();
    }

    String? profilesJson = _prefs.getString(_profilesKey);
    if (profilesJson != null) {
      try {
        Map<String, dynamic> decodedProfiles = jsonDecode(profilesJson);
        _savedProfiles = decodedProfiles.map(
          (key, value) => MapEntry(key, value as String),
        );
      } catch (e) {
        _savedProfiles = {};
      }
    }

    _errorLogs = _prefs.getStringList(_errorLogsKey) ?? [];

    String? themeJson = _prefs.getString('reading_theme');
    if (themeJson != null) {
      try {
        _currentReadingTheme = ReadingTheme.fromJson(jsonDecode(themeJson));
      } catch (e) {
        _currentReadingTheme = _defaultReadingTheme;
      }
    } else {
      _currentReadingTheme = _defaultReadingTheme;
    }
    String? savedLocale = _prefs.getString('app_locale');
    if (savedLocale != null) {
      _selectedLocale = Locale(savedLocale);
    }
    _volume =
        _prefs.getDouble('volume_level') ??
        _MyHomePageState._defaultVolumeSettings;

    setState(() {
      _selectedTTSProvider =
          TTSProvider.values[_prefs.getInt('tts_provider') ??
              TTSProvider.openai.index];
      _selectedModel =
          _prefs.getString('tts_model') ??
          _MyHomePageState._defaultOpenAIModelSettings;
      _selectedVoice =
          _prefs.getString('tts_voice') ??
          _MyHomePageState._defaultOpenAIVoiceSettings;
      _msRegion =
          _prefs.getString('ms_region') ??
          _MyHomePageState._defaultMsRegionSettings;
      _msSelectedLanguage =
          _prefs.getString('ms_language') ??
          _MyHomePageState._defaultMsLanguage;
      _msSelectedVoiceName =
          _prefs.getString('ms_voice_name') ??
          (_msHardcodedVoicesByLanguage[_msSelectedLanguage]?.first ?? '');

      _useProxy =
          _prefs.getBool('use_proxy') ??
          _MyHomePageState._defaultUseProxySettings;
      _proxyHost =
          _prefs.getString('proxy_host') ??
          _MyHomePageState._defaultProxyHostSettings;
      _proxyPort =
          _prefs.getString('proxy_port') ??
          _MyHomePageState._defaultProxyPortSettings;
      _playbackSpeed =
          _prefs.getDouble('playback_speed') ??
          _MyHomePageState._defaultPlaybackSpeedSettings;
      _maxCharsPerRequest =
          _prefs.getInt('max_chars_per_request') ??
          _MyHomePageState._defaultMaxCharsPerRequestSettings;
      _prefetchChunkCount =
          _prefs.getInt('prefetch_chunk_count') ??
          _MyHomePageState._defaultPrefetchChunkCountSettings;
      if (Platform.isWindows) {
        _windowsAudioPlayer.setPlaybackRate(_playbackSpeed);
        _windowsAudioPlayer.setVolume(_volume);
      } else {
        _justAudioPlayer.setSpeed(_playbackSpeed);
        _justAudioPlayer.setVolume(_volume);
      }
    });

    if (_selectedTTSProvider == TTSProvider.microsoft &&
        _msSubscriptionKey.isNotEmpty &&
        _msRegion.isNotEmpty) {
      await _fetchMicrosoftVoices(
        _msRegion,
        _msSubscriptionKey,
        initialLoad: true,
      );
    }

    _loadAndPromptForResume();
  }

  Future<void> _loadAndPromptForResume() async {
    _lastPlayedTextContentHash = _prefs.getInt('last_played_text_content_hash');
    _lastPlayedChunkStartIndex = _prefs.getInt('last_played_chunk_start_index');
    _lastPlayedPositionMillis = _prefs.getInt('last_played_position_millis');

    if (!_resumePromptShownThisSession &&
        _mainTextHolderController.text.isNotEmpty &&
        _lastPlayedTextContentHash != null &&
        _lastPlayedChunkStartIndex != null &&
        _lastPlayedPositionMillis != null &&
        _mainTextHolderController.text.hashCode == _lastPlayedTextContentHash) {
      _resumePromptShownThisSession = true;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_tr('resumePromptMessage')),
              duration: const Duration(seconds: 10),
              action: SnackBarAction(
                label: _tr('yesButton'),
                onPressed: () {
                  _resumePlayback();
                },
              ),
            ),
          );
        }
      });
    }
  }

  Future<void> _saveCurrentPlaybackProgress(
    int currentChunkListIndex,
    Duration position,
  ) async {
    if (!mounted ||
        currentChunkListIndex < 0 ||
        currentChunkListIndex >= _processedTextChunks.length)
      return;

    final chunkData = _processedTextChunks[currentChunkListIndex];
    final int chunkStartIndex = chunkData['startIndex'] as int;

    await _prefs.setInt(
      'last_played_text_content_hash',
      _mainTextHolderController.text.hashCode,
    );
    await _prefs.setInt('last_played_chunk_start_index', chunkStartIndex);
    await _prefs.setInt('last_played_position_millis', position.inMilliseconds);
    // _toggleBookmark(chunkStartIndex, autoAddOnly: true); // Removed auto-bookmarking
  }

  Future<void> _clearLastPlayedProgress() async {
    await _prefs.remove('last_played_text_content_hash');
    await _prefs.remove('last_played_chunk_start_index');
    await _prefs.remove('last_played_position_millis');
    if (mounted) {
      setState(() {
        _lastPlayedTextContentHash = null;
        _lastPlayedChunkStartIndex = null;
        _lastPlayedPositionMillis = null;
      });
    }
  }

  Future<void> _resumePlayback() async {
    if (_lastPlayedChunkStartIndex == null || _lastPlayedPositionMillis == null)
      return;

    final textToSpeak = _mainTextHolderController.text;
    if (_currentTextForDisplay != textToSpeak || _processedTextChunks.isEmpty) {
      setState(() {
        _currentTextForDisplay = textToSpeak;
        _processedTextChunks = _splitTextIntoDetailedChunks(
          _currentTextForDisplay,
          _maxCharsPerRequest,
        );
        _chunkKeys = List.generate(
          _processedTextChunks.length,
          (_) => GlobalKey(),
        );
      });
    }
    if (_processedTextChunks.isEmpty) return;

    int targetChunkDisplayIndex = -1;
    for (int i = 0; i < _processedTextChunks.length; i++) {
      if (_processedTextChunks[i]['startIndex'] == _lastPlayedChunkStartIndex) {
        targetChunkDisplayIndex = i;
        break;
      }
    }

    if (targetChunkDisplayIndex != -1) {
      await _initiatePlaybackFromIndex(
        targetChunkDisplayIndex,
        resumePosition: Duration(milliseconds: _lastPlayedPositionMillis!),
      );
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '无法找到上次的进度点，将从头开始。(Could not find last position, starting from beginning.)',
            ),
          ),
        );
      }
      await _speakText();
    }
    await _clearLastPlayedProgress();
  }

  Future<void> _saveBookmarks() async {
    await _prefs.setStringList(
      'bookmarks_list',
      _bookmarks.map((i) => i.toString()).toList(),
    );
  }

  Future<void> _addErrorLog(String message) async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final logEntry = "[$timestamp] $message";

    setState(() {
      _errorLogs.insert(0, logEntry);
      if (_errorLogs.length > _maxLogEntries) {
        _errorLogs = _errorLogs.sublist(0, _maxLogEntries);
      }
    });
    await _prefs.setStringList(_errorLogsKey, _errorLogs);
  }

  Future<void> _clearErrorLogs() async {
    setState(() {
      _errorLogs.clear();
    });
    await _prefs.remove(_errorLogsKey);
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('错误日志已清除。(Error logs cleared.)')),
      );
  }

  Future<void> _persistCurrentActiveSettings() async {
    if (_apiKey.isNotEmpty) {
      await _secureStorage.write(key: 'openai_api_key', value: _apiKey);
    } else {
      await _secureStorage.delete(key: 'openai_api_key');
    }
    if (_msSubscriptionKey.isNotEmpty) {
      await _secureStorage.write(key: 'ms_tts_key', value: _msSubscriptionKey);
    } else {
      await _secureStorage.delete(key: 'ms_tts_key');
    }

    await _prefs.setInt('tts_provider', _selectedTTSProvider.index);
    await _prefs.setString('main_text_content', _mainTextHolderController.text);
    await _prefs.setString('tts_model', _selectedModel);
    await _prefs.setString('tts_voice', _selectedVoice);
    await _prefs.setString('ms_region', _msRegion);
    await _prefs.setString('ms_language', _msSelectedLanguage);
    await _prefs.setString('ms_voice_name', _msSelectedVoiceName);

    await _prefs.setBool('use_proxy', _useProxy);
    await _prefs.setString('proxy_host', _proxyHost);
    await _prefs.setString('proxy_port', _proxyPort);
    await _prefs.setInt('max_chars_per_request', _maxCharsPerRequest);
    await _prefs.setInt('prefetch_chunk_count', _prefetchChunkCount);
    await _prefs.setDouble('playback_speed', _playbackSpeed);
    await _prefs.setDouble('volume_level', _volume); // Save volume
    await _prefs.setString(
      'reading_theme',
      jsonEncode(_currentReadingTheme.toJson()),
    );
    await _prefs.setString('app_locale', _selectedLocale.languageCode);
    await _saveBookmarks();
  }

  Future<void> _saveSettingsDialogValues({
    required TTSProvider ttsProvider,
    required String openAIApiKey,
    required String msSubscriptionKey,
    required String msRegion,
    required String msLanguage,
    required String msVoiceName,
    required String model, // OpenAI model
    required String voice, // OpenAI voice
    required bool useProxy,
    required String proxyHost,
    required String proxyPort,
    required int maxChars,
    required int prefetchCount,
    required ReadingTheme readingTheme,
    Locale? appLocale,
  }) async {
    _selectedTTSProvider = ttsProvider;
    _apiKey = openAIApiKey;
    _msSubscriptionKey = msSubscriptionKey;
    _msRegion = msRegion;
    _msSelectedLanguage = msLanguage;
    _msSelectedVoiceName = msVoiceName;
    _selectedModel = model;
    _selectedVoice = voice;
    _useProxy = useProxy;
    _proxyHost = proxyHost;
    _proxyPort = proxyPort;
    _maxCharsPerRequest = maxChars;
    _prefetchChunkCount = prefetchCount;
    _currentReadingTheme = readingTheme;
    if (appLocale != null) {
      _selectedLocale = appLocale;
    }

    await _persistCurrentActiveSettings();

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已应用! (Settings applied!)')),
      );
    }
  }

  Future<void> _resetSettingsToDefaults() async {
    await _secureStorage.delete(key: 'openai_api_key');
    await _secureStorage.delete(key: 'ms_tts_key');
    _apiKey = '';
    _msSubscriptionKey = '';
    _mainTextHolderController.text = '';

    _selectedTTSProvider = TTSProvider.openai;
    _selectedModel = _MyHomePageState._defaultOpenAIModelSettings;
    _selectedVoice = _MyHomePageState._defaultOpenAIVoiceSettings;
    _msRegion = _MyHomePageState._defaultMsRegionSettings;
    _msSelectedLanguage = _MyHomePageState._defaultMsLanguage;
    _msSelectedVoiceName =
        _msHardcodedVoicesByLanguage[_MyHomePageState._defaultMsLanguage]
            ?.first ??
        '';

    _useProxy = _MyHomePageState._defaultUseProxySettings;
    _proxyHost = _MyHomePageState._defaultProxyHostSettings;
    _proxyPort = _MyHomePageState._defaultProxyPortSettings;
    _maxCharsPerRequest = _MyHomePageState._defaultMaxCharsPerRequestSettings;
    _prefetchChunkCount = _MyHomePageState._defaultPrefetchChunkCountSettings;
    _currentReadingTheme = _defaultReadingTheme;
    _selectedLocale = const Locale('zh'); // Reset locale to Chinese

    await _setPlaybackSpeed(
      _MyHomePageState._defaultPlaybackSpeedSettings,
      save: true,
    );
    await _setVolume(_MyHomePageState._defaultVolumeSettings, save: true);

    // Persist all defaults as active settings
    await _persistCurrentActiveSettings();

    _bookmarks.clear();
    await _saveBookmarks();
    await _clearLastPlayedProgress(); // Also clear any resume progress

    await _resetTTSState();

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('设置已重置为默认值。(Settings reset to defaults.)'),
        ),
      );
    }
  }

  Future<void> _setPlaybackSpeed(double newSpeed, {bool save = true}) async {
    final clampedSpeed = newSpeed.clamp(_minPlaybackSpeed, _maxPlaybackSpeed);
    if (mounted) {
      setState(() {
        _playbackSpeed = clampedSpeed;
      });
    }
    if (Platform.isWindows) {
      await _windowsAudioPlayer.setPlaybackRate(clampedSpeed);
    } else {
      await _justAudioPlayer.setSpeed(clampedSpeed);
    }
    if (save) {
      await _prefs.setDouble('playback_speed', clampedSpeed);
    }
  }

  Future<void> _setVolume(double newVolume, {bool save = true}) async {
    final clampedVolume = newVolume.clamp(0.0, 1.0);
    if (mounted) {
      setState(() {
        _volume = clampedVolume;
      });
    }
    if (Platform.isWindows) {
      await _windowsAudioPlayer.setVolume(clampedVolume);
    } else {
      await _justAudioPlayer.setVolume(clampedVolume);
    }
    if (save) {
      await _prefs.setDouble('volume_level', clampedVolume);
    }
  }

  http.Client _getHttpClient({
    bool? useDialogProxy,
    String? dialogProxyHost,
    String? dialogProxyPort,
  }) {
    bool actualUseProxy = useDialogProxy ?? _useProxy;
    String actualProxyHost = dialogProxyHost ?? _proxyHost;
    String actualProxyPort = dialogProxyPort ?? _proxyPort;

    if (actualUseProxy &&
        actualProxyHost.isNotEmpty &&
        actualProxyPort.isNotEmpty) {
      final proxyPortNum = int.tryParse(actualProxyPort);
      if (proxyPortNum != null) {
        final httpClient = HttpClient();
        httpClient.findProxy = (uri) {
          return "PROXY $actualProxyHost:$proxyPortNum;";
        };
        return IOClient(httpClient);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '代理端口号无效，将不使用代理。 (Invalid proxy port, proxy will not be used.)',
              ),
            ),
          );
        }
      }
    }
    return http.Client();
  }

  List<Map<String, dynamic>> _splitTextIntoDetailedChunks(
    String text,
    int chunkSize,
  ) {
    List<Map<String, dynamic>> chunks = [];
    if (text.isEmpty || chunkSize <= 0) {
      return chunks;
    }
    for (int i = 0; i < text.length; i += chunkSize) {
      int endIndex = i + chunkSize > text.length ? text.length : i + chunkSize;
      chunks.add({
        'text': text.substring(i, endIndex),
        'startIndex': i,
        'endIndex': endIndex,
        'durationMillis': null,
      });
    }
    return chunks;
  }

  Future<void> _resetTTSState() async {
    if (Platform.isWindows) {
      await _windowsAudioPlayer.stop();
      await _clearWindowsPreloadedChunks(); // Clear any temp files
    } else {
      await _justAudioPlayer.stop();
      try {
        await _justAudioPlayer.setAudioSource(
          ja.ConcatenatingAudioSource(children: []),
        );
      } catch (e) {
        // ignore
      }
      _playlist?.clear().catchError((_) {
        /* ignore */
      });
      _playlist = null;
    }

    _processedTextChunks = [];
    _chunkKeys = [];
    _currentlyPlayingChunkIndex = -1;
    _highlightedCharacterInChunkIndex = -1;
    _currentTextForDisplay = "";
    _currentlyFetchingChunkText = null;
    _isBufferingInBackground = false;
    _backgroundBufferingPreviewText = null;

    _currentChunkIndexToFetch = 0;
    _isFetchingMore = false;
    await _currentIndexSubscription?.cancel();
    _currentIndexSubscription = null;

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initiatePlaybackFromIndex(
    int startChunkIndex, {
    Duration? resumePosition,
  }) async {
    if (!mounted) return;

    final textToSpeak = _mainTextHolderController.text;
    if (textToSpeak.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可朗读的文本。(No text to read.)')),
        );
      return;
    }

    if (_currentTextForDisplay != textToSpeak || _processedTextChunks.isEmpty) {
      setState(() {
        _currentTextForDisplay = textToSpeak;
        _processedTextChunks = _splitTextIntoDetailedChunks(
          _currentTextForDisplay,
          _maxCharsPerRequest,
        );
        _chunkKeys = List.generate(
          _processedTextChunks.length,
          (_) => GlobalKey(),
        );
        _highlightedCharacterInChunkIndex = -1;
      });
    }

    if (startChunkIndex < 0 || startChunkIndex >= _processedTextChunks.length) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('无效的起始片段索引。(Invalid starting chunk index.)'),
          ),
        );
      }
      return;
    }

    if (Platform.isWindows) {
      await _windowsAudioPlayer.stop();
      await _clearWindowsPreloadedChunks();
      _currentChunkIndexToFetch = startChunkIndex;
    } else {
      await _justAudioPlayer.stop();
      _playlist?.clear().catchError((_) {});
      _playlist = ja.ConcatenatingAudioSource(children: []);
      _currentChunkIndexToFetch = startChunkIndex;
    }

    _currentlyPlayingChunkIndex = -1;
    _highlightedCharacterInChunkIndex = -1;
    _isFetchingMore = false;
    await _currentIndexSubscription?.cancel();
    _currentIndexSubscription = null;

    setState(() {
      _isLoading = true;
      _currentlyFetchingChunkText = null;
    });
    // _updateFabVisibilityBasedOnPlayback(); // Removed

    if (Platform.isWindows) {
      // Initial preloading for Windows
      for (
        int i = 0;
        i < _prefetchChunkCount &&
            _currentChunkIndexToFetch < _processedTextChunks.length;
        i++
      ) {
        await _preloadNextWindowsChunk(); // Await initial preloads
      }
      if (_windowsPreloadedChunks.isNotEmpty) {
        await _startWindowsPlaybackFromQueue(resumePosition: resumePosition);
      } else if (_processedTextChunks.isNotEmpty) {
        // If no preloaded but chunks exist (e.g. prefetch = 0 or failed)
        await _fetchAndPlaySingleChunkWindows(
          startChunkIndex,
          resumePosition: resumePosition,
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('未能预加载音频片段。(Failed to preload audio segments.)'),
            ),
          );
          setState(() {
            _isLoading = false;
          });
          // _showFabs(); // Removed
        }
      }
    } else {
      // Non-Windows
      final int playbackSessionStartChunkIndex = _currentChunkIndexToFetch;
      bool fetchSuccess = await _fetchAndAddChunksToPlaylist(
        count: _prefetchChunkCount,
      );

      if (fetchSuccess &&
          _playlist != null &&
          _playlist!.length > 0 &&
          mounted) {
        try {
          await _justAudioPlayer.setSpeed(_playbackSpeed);
          await _justAudioPlayer.setAudioSource(
            _playlist!,
            initialIndex: 0,
            preload: true,
          );

          if (resumePosition != null && resumePosition.inMilliseconds > 0) {
            await _justAudioPlayer.seek(resumePosition, index: 0);
          }
          _justAudioPlayer.play();
          if (mounted)
            setState(() {
              _isLoading = false;
              _currentlyFetchingChunkText = null;
            });

          _currentIndexSubscription = _justAudioPlayer.currentIndexStream
              .listen((playlistIdx) {
                if (playlistIdx != null && _playlist != null && mounted) {
                  final int actualChunkIndexInProcessedList =
                      playbackSessionStartChunkIndex + playlistIdx;
                  if (actualChunkIndexInProcessedList <
                      _processedTextChunks.length) {
                    setState(() {
                      _currentlyPlayingChunkIndex =
                          actualChunkIndexInProcessedList;
                      _highlightedCharacterInChunkIndex = -1;
                    });
                    _saveCurrentPlaybackProgress(
                      actualChunkIndexInProcessedList,
                      Duration.zero,
                    );

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted &&
                          actualChunkIndexInProcessedList < _chunkKeys.length &&
                          _chunkKeys[actualChunkIndexInProcessedList]
                                  .currentContext !=
                              null) {
                        Scrollable.ensureVisible(
                          _chunkKeys[actualChunkIndexInProcessedList]
                              .currentContext!,
                          duration: const Duration(milliseconds: 350),
                          alignment: 0.3,
                          curve: Curves.easeInOut,
                        );
                      }
                    });
                    final int remainingInPlaylist =
                        _playlist!.length - 1 - playlistIdx;
                    if (remainingInPlaylist < _refetchThreshold &&
                        !_isFetchingMore &&
                        _currentChunkIndexToFetch <
                            _processedTextChunks.length) {
                      _fetchMoreChunksInBackground();
                    }
                  }
                }
              });
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '设置音频源或播放失败 (Error setting audio source or playing): $e',
                ),
              ),
            );
            setState(() {
              _isLoading = false;
              _currentlyFetchingChunkText = null;
            });
            // _showFabs(); // Removed
          }
        }
      } else {
        if (mounted) {
          if (!fetchSuccess && _processedTextChunks.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('未能获取音频片段。(Failed to fetch audio segments.)'),
              ),
            );
          }
          setState(() {
            _isLoading = false;
            _currentlyFetchingChunkText = null;
          });
          // _showFabs(); // Removed
        }
      }
    }
  }

  Future<String> _getTempFilePath(int chunkIndex) async {
    final directory = await getTemporaryDirectory();
    return '${directory.path}/tts_chunk_$chunkIndex.mp3';
  }

  Future<void> _clearWindowsPreloadedChunks() async {
    for (var preloadedChunk in _windowsPreloadedChunks) {
      try {
        final file = File(preloadedChunk.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _addErrorLog("Error deleting temp file ${preloadedChunk.filePath}: $e");
      }
    }
    _windowsPreloadedChunks.clear();
  }

  Future<void> _preloadNextWindowsChunk() async {
    if (!Platform.isWindows ||
        _currentChunkIndexToFetch >= _processedTextChunks.length ||
        _windowsPreloadedChunks.length >= _prefetchChunkCount) {
      if (mounted && _windowsPreloadedChunks.length >= _prefetchChunkCount) {
        // If buffer is full, stop showing buffering
        setState(() {
          _isBufferingInBackground = false;
          _backgroundBufferingPreviewText = null;
        });
      }
      return;
    }

    final chunkData = _processedTextChunks[_currentChunkIndexToFetch];
    final String chunkText = chunkData['text'] as String;
    final int originalIndex = _currentChunkIndexToFetch;

    if (mounted) {
      setState(() {
        _isBufferingInBackground = true;
        _backgroundBufferingPreviewText = chunkText;
      });
    }

    final client = _getHttpClient();
    FetchAttemptResult fetchResult = await _attemptFetchChunkWithRetries(
      chunkText,
      originalIndex + 1,
      client,
    );

    if (mounted) {
      if (fetchResult.status == RetryStatus.success &&
          fetchResult.audioBytes != null) {
        try {
          final filePath = await _getTempFilePath(originalIndex);
          final file = File(filePath);
          await file.writeAsBytes(fetchResult.audioBytes!);
          _windowsPreloadedChunks.add(
            WindowsPreloadedChunk(
              originalChunkIndex: originalIndex,
              filePath: filePath,
              text: chunkText,
            ),
          );
          _currentChunkIndexToFetch++; // Move to next chunk for further preloading
        } catch (e) {
          _addErrorLog("Error saving preloaded chunk $originalIndex: $e");
        }
      } else {
        _addErrorLog("Failed to fetch chunk $originalIndex for preloading.");
      }
      if (client is IOClient)
        client.close();
      else if (client is http.Client && client != http.Client())
        client.close();

      // Check if this was the last chunk to be preloaded in the current batch or if all chunks are fetched
      bool stillNeedToPreloadMoreForThisBatch =
          _windowsPreloadedChunks.length < _prefetchChunkCount &&
          _currentChunkIndexToFetch < _processedTextChunks.length;
      if (!stillNeedToPreloadMoreForThisBatch ||
          _currentChunkIndexToFetch >= _processedTextChunks.length) {
        setState(() {
          _isBufferingInBackground = false;
          _backgroundBufferingPreviewText = null;
        });
      }
    }
  }

  Future<void> _startWindowsPlaybackFromQueue({
    Duration? resumePosition,
  }) async {
    if (!Platform.isWindows || !mounted || _windowsPreloadedChunks.isEmpty) {
      if (mounted) {
        setState(() => _isLoading = false);
        // _showFabs(); // Removed
      }
      return;
    }

    final chunkToPlay =
        _windowsPreloadedChunks.first; // Get the next chunk from the queue

    setState(() {
      _isLoading = true; // Still true as we are about to play
      _currentlyPlayingChunkIndex = chunkToPlay.originalChunkIndex;
      _currentlyFetchingChunkText = chunkToPlay.text;
    });

    try {
      await _windowsAudioPlayer.setSource(
        ap.DeviceFileSource(chunkToPlay.filePath),
      );
      await _windowsAudioPlayer.setPlaybackRate(_playbackSpeed);
      if (resumePosition != null && resumePosition.inMilliseconds > 0) {
        await _windowsAudioPlayer.seek(resumePosition);
      }
      await _windowsAudioPlayer.resume();
      if (mounted)
        setState(() {
          _isLoading = false;
          _currentlyFetchingChunkText = null;
        });
      _saveCurrentPlaybackProgress(
        chunkToPlay.originalChunkIndex,
        Duration.zero,
      );
    } catch (e) {
      _addErrorLog(
        "Windows playback from queue failed for chunk ${chunkToPlay.originalChunkIndex}: $e",
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Windows播放失败: $e")));
        setState(() {
          _isLoading = false;
          _currentlyFetchingChunkText = null;
          _currentlyPlayingChunkIndex = -1;
        });
        // _showFabs(); // Removed
      }
    }
  }

  Future<void> _fetchAndPlaySingleChunkWindows(
    int chunkIndex, {
    Duration? resumePosition,
  }) async {
    if (!mounted ||
        chunkIndex < 0 ||
        chunkIndex >= _processedTextChunks.length) {
      setState(() => _isLoading = false);
      // _showFabs(); // Removed
      return;
    }
    setState(() {
      _isLoading = true;
      _currentlyPlayingChunkIndex = chunkIndex;
      _currentlyFetchingChunkText =
          _processedTextChunks[chunkIndex]['text'] as String?;
    });

    final client = _getHttpClient();
    FetchAttemptResult fetchResult = await _attemptFetchChunkWithRetries(
      _processedTextChunks[chunkIndex]['text'] as String,
      chunkIndex + 1,
      client,
    );

    if (mounted) {
      if (fetchResult.status == RetryStatus.success &&
          fetchResult.audioBytes != null) {
        try {
          final filePath = await _getTempFilePath(chunkIndex);
          final file = File(filePath);
          await file.writeAsBytes(fetchResult.audioBytes!);

          await _windowsAudioPlayer.setSource(ap.DeviceFileSource(filePath));
          await _windowsAudioPlayer.setPlaybackRate(_playbackSpeed);
          if (resumePosition != null && resumePosition.inMilliseconds > 0) {
            await _windowsAudioPlayer.seek(resumePosition);
          }
          await _windowsAudioPlayer.resume();
          setState(() {
            _isLoading = false;
            _currentlyFetchingChunkText = null;
          });
          _saveCurrentPlaybackProgress(chunkIndex, Duration.zero);
          // Add to preloaded chunks so it can be cleaned up
          _windowsPreloadedChunks.add(
            WindowsPreloadedChunk(
              originalChunkIndex: chunkIndex,
              filePath: filePath,
              text: _processedTextChunks[chunkIndex]['text'] as String,
            ),
          );
        } catch (e) {
          _addErrorLog("Windows播放失败 (Windows playback failed): $e");
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Windows播放失败: $e")));
          setState(() {
            _isLoading = false;
            _currentlyFetchingChunkText = null;
            _currentlyPlayingChunkIndex = -1;
          });
          // _showFabs(); // Removed
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('获取音频片段失败。(Failed to fetch audio segment.)'),
          ),
        );
        setState(() {
          _isLoading = false;
          _currentlyFetchingChunkText = null;
          _currentlyPlayingChunkIndex = -1;
        });
        // _showFabs(); // Removed
      }
    }
    if (client is IOClient)
      client.close();
    else if (client is http.Client && client != http.Client())
      client.close();
  }

  Future<void> _speakText() async {
    if (_isCurrentlyPlaying() || _isLoading) {
      await _stopPlayback();
    }
    await _clearLastPlayedProgress();

    final textToSpeak = _mainTextHolderController.text;

    if (_selectedTTSProvider == TTSProvider.openai && _apiKey.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '请在设置中输入您的 OpenAI API Key。(Please enter your OpenAI API Key in settings.)',
            ),
          ),
        );
      return;
    }
    if (_selectedTTSProvider == TTSProvider.microsoft &&
        (_msSubscriptionKey.isEmpty || _msRegion.isEmpty)) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '请在设置中输入您的 Microsoft TTS 订阅密钥和区域。(Please enter your Microsoft TTS Subscription Key and Region in settings.)',
            ),
          ),
        );
      return;
    }

    if (textToSpeak.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '请先通过右下角按钮输入或加载文本。(Please input or load text via the bottom-right button.)',
            ),
          ),
        );
      return;
    }

    final String currentMainText = _mainTextHolderController.text;
    if (!_isCurrentlyPlaying() && !_isLoading) {
      await _resetTTSState();
    }
    _mainTextHolderController.text = currentMainText;

    setState(() {
      _currentTextForDisplay = currentMainText;
      _processedTextChunks = _splitTextIntoDetailedChunks(
        _currentTextForDisplay,
        _maxCharsPerRequest,
      );
      _chunkKeys = List.generate(
        _processedTextChunks.length,
        (_) => GlobalKey(),
      );
      _highlightedCharacterInChunkIndex = -1;
    });

    if (_processedTextChunks.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '文本为空或最大字符数设置无效，无需处理。(Text is empty or max chars setting is invalid, nothing to process.)',
            ),
          ),
        );
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    await _initiatePlaybackFromIndex(0);
  }

  Future<FetchAttemptResult> _attemptFetchChunkWithRetries(
    String chunkText,
    int chunkDisplayIndex,
    http.Client client, {
    bool isTest = false,
  }) async {
    const int maxAutoRetriesPerCycle = 3;
    const Duration retryDelay = Duration(seconds: 3);

    while (true) {
      int autoRetryCount = 0;

      while (autoRetryCount < maxAutoRetriesPerCycle) {
        if (!mounted)
          return FetchAttemptResult(null, RetryStatus.failedAndUserCancelled);

        if (autoRetryCount > 0 && !isTest) {
          await Future.delayed(retryDelay);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '正在自动重试文本块 $chunkDisplayIndex (第 ${autoRetryCount + 1} 次)... (Auto-retrying chunk $chunkDisplayIndex (attempt ${autoRetryCount + 1})...)',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }

        http.Response response;
        try {
          if (_selectedTTSProvider == TTSProvider.openai) {
            response = await client.post(
              Uri.parse('https://api.openai.com/v1/audio/speech'),
              headers: {
                'Authorization': 'Bearer $_apiKey',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'model': _selectedModel,
                'input': chunkText,
                'voice': _selectedVoice,
                'response_format': 'mp3',
              }),
            );
          } else {
            // Microsoft TTS
            String ssml = """
                <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$_msSelectedLanguage'>
                    <voice name='${_msSelectedVoiceName.isNotEmpty ? _msSelectedVoiceName : _getMicrosoftDefaultVoiceForLanguage(_msSelectedLanguage)}'>
                        ${_escapeXml(chunkText)}
                    </voice>
                </speak>
            """;
            response = await client.post(
              Uri.parse(
                'https://$_msRegion.tts.speech.microsoft.com/cognitiveservices/v1',
              ),
              headers: {
                'Ocp-Apim-Subscription-Key': _msSubscriptionKey,
                'Content-Type': 'application/ssml+xml',
                'X-Microsoft-OutputFormat': 'audio-16khz-128kbitrate-mono-mp3',
                'User-Agent': 'FlutterTTSApp',
              },
              body: ssml,
            );
          }
        } catch (e) {
          final logMessage =
              '请求文本块 $chunkDisplayIndex 失败 (第 ${autoRetryCount + 1} 次尝试): $e (Request for chunk $chunkDisplayIndex failed (attempt ${autoRetryCount + 1}): $e)';
          if (!isTest) _addErrorLog(logMessage);
          if (mounted && !isTest) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(logMessage)));
          }
          autoRetryCount++;
          if (autoRetryCount >= maxAutoRetriesPerCycle) break;
          continue;
        }

        if (response.statusCode == 200) {
          return FetchAttemptResult(response.bodyBytes, RetryStatus.success);
        } else {
          final String errorMessage = _parseErrorFromResponse(response);
          final logMessage =
              '文本块 $chunkDisplayIndex API错误 (第 ${autoRetryCount + 1} 次尝试): ${response.statusCode} - $errorMessage (Chunk $chunkDisplayIndex API error (attempt ${autoRetryCount + 1}): ${response.statusCode} - $errorMessage)';
          if (!isTest) _addErrorLog(logMessage);
          if (mounted && !isTest) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(logMessage)));
          }
          autoRetryCount++;
        }
      }

      if (!mounted)
        return FetchAttemptResult(null, RetryStatus.failedAndUserCancelled);
      if (!isTest)
        _addErrorLog(
          '文本块 $chunkDisplayIndex 自动重试 $maxAutoRetriesPerCycle 次后失败。(Chunk $chunkDisplayIndex failed after $maxAutoRetriesPerCycle auto-retries.)',
        );

      if (isTest)
        return FetchAttemptResult(
          null,
          RetryStatus.failedAfterMaxRetries,
        ); // For test, don't show dialog

      final bool userWantsToRetry = await _showRetryDialog(
        context,
        '文本块 $chunkDisplayIndex 自动重试失败。是否继续？ (Chunk $chunkDisplayIndex auto-retry failed. Continue?)',
      );

      if (!userWantsToRetry) {
        if (!isTest)
          _addErrorLog(
            '用户选择不对文本块 $chunkDisplayIndex 进行更多重试。(User chose not to retry chunk $chunkDisplayIndex further.)',
          );
        return FetchAttemptResult(null, RetryStatus.failedAndUserCancelled);
      }
      if (!isTest)
        _addErrorLog(
          '用户选择对文本块 $chunkDisplayIndex 继续重试。(User chose to continue retrying chunk $chunkDisplayIndex.)',
        );
    }
  }

  String _getMicrosoftDefaultVoiceForLanguage(String lang) {
    return _msHardcodedVoicesByLanguage[lang]?.first ??
        _msHardcodedVoicesByLanguage['en-US']!.first;
  }

  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  String _parseErrorFromResponse(http.Response response) {
    try {
      final errorBody = jsonDecode(response.body);
      return errorBody['error']?['message'] ?? '未知错误 (Unknown error)';
    } catch (_) {
      return response.body.isNotEmpty ? response.body : '未知错误 (Unknown error)';
    }
  }

  Future<bool> _showRetryDialog(BuildContext context, String message) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('重试确认 (Retry Confirmation)'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('否 (No)'),
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
            ),
            ElevatedButton(
              child: const Text('是 (Yes)'),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<bool> _fetchAndAddChunksToPlaylist({required int count}) async {
    if (Platform.isWindows) {
      // This method is for just_audio's concatenating source, not used for Windows with audioplayers
      return false;
    }
    if (_playlist == null) return false;

    final client = _getHttpClient();
    int successfullyFetchedCount = 0;
    bool clientNeedsClosing = client is IOClient;

    try {
      for (
        int i = 0;
        i < count &&
            _currentChunkIndexToFetch <
                _processedTextChunks.length; /* i incremented on success */
      ) {
        if (!mounted) return false;

        final chunkData = _processedTextChunks[_currentChunkIndexToFetch];
        final chunkText = chunkData['text'] as String;
        final chunkDisplayIndexForMessage = _currentChunkIndexToFetch + 1;

        if (mounted && _isLoading) {
          setState(() {
            _currentlyFetchingChunkText = chunkText;
          });
        }

        FetchAttemptResult fetchResult = await _attemptFetchChunkWithRetries(
          chunkText,
          chunkDisplayIndexForMessage,
          client,
        );

        if (fetchResult.status == RetryStatus.success &&
            fetchResult.audioBytes != null) {
          final Uint8List audioBytes = fetchResult.audioBytes!;
          ja.AudioPlayer tempPlayer = ja.AudioPlayer();
          Duration? audioDuration;
          try {
            audioDuration = await tempPlayer.setAudioSource(
              BytesAudioSource(audioBytes),
            );
          } catch (e) {
            _addErrorLog(
              "获取音频块 $chunkDisplayIndexForMessage 时长失败: $e (Error getting duration for chunk $chunkDisplayIndexForMessage: $e)",
            );
          } finally {
            await tempPlayer.dispose();
          }

          _processedTextChunks[_currentChunkIndexToFetch]['durationMillis'] =
              audioDuration?.inMilliseconds;

          try {
            if (_playlist != null) {
              await _playlist!.add(
                BytesAudioSource(audioBytes, contentType: 'audio/mpeg'),
              );
              _currentChunkIndexToFetch++;
              successfullyFetchedCount++;
              i++;
            } else {
              break;
            }
          } catch (e) {
            _addErrorLog(
              "添加音频块 $chunkDisplayIndexForMessage 到播放列表失败: $e (Error adding audio chunk $chunkDisplayIndexForMessage to playlist: $e)",
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '添加音频到播放列表失败 (Error adding audio to playlist): $e',
                  ),
                ),
              );
            }
            break;
          }
        } else {
          _addErrorLog(
            "文本块 $chunkDisplayIndexForMessage 获取失败，状态: ${fetchResult.status}。(Chunk $chunkDisplayIndexForMessage fetch failed, status: ${fetchResult.status}.)",
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '已停止处理文本块 $chunkDisplayIndexForMessage。(Processing stopped for chunk $chunkDisplayIndexForMessage.)',
                ),
              ),
            );
          }
          break;
        }
      }
    } finally {
      if (clientNeedsClosing && client is IOClient) {
        client.close();
      }
    }
    return successfullyFetchedCount > 0;
  }

  Future<void> _fetchMoreChunksInBackground() async {
    if (Platform.isWindows) {
      // For Windows, preloading is handled differently (one by one into files)
      if (_windowsPreloadedChunks.length < _prefetchChunkCount &&
          _currentChunkIndexToFetch < _processedTextChunks.length) {
        await _preloadNextWindowsChunk();
      }
      return;
    }
    if (_isFetchingMore || _playlist == null || !mounted) return;

    _isFetchingMore = true;
    String? previewTextForThisBatch;
    if (_currentChunkIndexToFetch < _processedTextChunks.length) {
      previewTextForThisBatch =
          _processedTextChunks[_currentChunkIndexToFetch]['text'] as String?;
    }

    if (mounted) {
      setState(() {
        _isBufferingInBackground = true;
        _backgroundBufferingPreviewText = previewTextForThisBatch;
      });
    }

    await _fetchAndAddChunksToPlaylist(count: _prefetchChunkCount);

    _isFetchingMore = false;
    if (mounted) {
      setState(() {
        _isBufferingInBackground = false;
        _backgroundBufferingPreviewText = null;
      });
    }
  }

  Future<void> _fetchMicrosoftVoices(
    String region,
    String key, {
    bool initialLoad = false,
    Function(bool)? setLoadingInDialog,
  }) async {
    if (key.isEmpty || region.isEmpty) {
      if (!initialLoad && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'MS Key 或 Region 未提供。(MS Key or Region not provided.)',
            ),
          ),
        );
      }
      return;
    }
    if (setLoadingInDialog != null)
      setLoadingInDialog(true);
    else if (mounted)
      setState(() => _isFetchingMsVoices = true);

    final client = _getHttpClient();
    Map<String, List<String>> fetchedVoices = {};
    String? fetchError;

    try {
      final response = await client.get(
        Uri.parse(
          'https://$region.tts.speech.microsoft.com/cognitiveservices/voices/list',
        ),
        headers: {'Ocp-Apim-Subscription-Key': key},
      );

      if (response.statusCode == 200) {
        List<dynamic> voicesData = jsonDecode(response.body);
        for (var voiceData in voicesData) {
          if (voiceData is Map<String, dynamic>) {
            String? shortName = voiceData['ShortName'];
            String? locale = voiceData['Locale'];
            if (shortName != null && locale != null) {
              if (fetchedVoices.containsKey(locale)) {
                fetchedVoices[locale]!.add(shortName);
              } else {
                fetchedVoices[locale] = [shortName];
              }
            }
          }
        }
        if (mounted) {
          setState(() {
            _dynamicMsVoicesByLanguage = fetchedVoices;
          });
          if (!initialLoad)
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Microsoft 语音列表已更新。(MS voice list updated.)'),
                backgroundColor: Colors.green,
              ),
            );
        }
      } else {
        fetchError =
            '获取 Microsoft 语音列表失败: ${response.statusCode} - ${_parseErrorFromResponse(response)} (Failed to fetch MS voices)';
      }
    } catch (e) {
      fetchError = '获取 Microsoft 语音列表出错: $e (Error fetching MS voices)';
    } finally {
      if (client is IOClient)
        client.close();
      else if (client is http.Client && client != http.Client())
        client.close();
      if (setLoadingInDialog != null)
        setLoadingInDialog(false);
      else if (mounted)
        setState(() => _isFetchingMsVoices = false);
      if (fetchError != null && mounted && !initialLoad) {
        _addErrorLog(fetchError);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(fetchError), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    if (Platform.isWindows) {
      if (_windowsAudioPlayer.state == ap.PlayerState.playing &&
          _currentlyPlayingChunkIndex != -1) {
        await _saveCurrentPlaybackProgress(
          _currentlyPlayingChunkIndex,
          await _windowsAudioPlayer.getCurrentPosition() ?? Duration.zero,
        );
      }
      await _windowsAudioPlayer.stop();
    } else {
      if (_justAudioPlayer.playing && _currentlyPlayingChunkIndex != -1) {
        await _saveCurrentPlaybackProgress(
          _currentlyPlayingChunkIndex,
          _justAudioPlayer.position,
        );
      }
      await _justAudioPlayer.stop();
    }
    await _resetTTSState(); // This also sets _isLoading = false if it was true
    if (mounted) {
      setState(() {
        _isLoading = false; // Ensure isLoading is false after stopping
      });
      // _showFabs(); // Removed
    }
  }

  Future<void> _testTTSConfiguration(
    BuildContext dialogContext,
    Function(bool) setLoadingState, {
    required TTSProvider provider,
    String? openAIApiKey,
    String? openAIModel,
    String? openAIVoice,
    String? msKey,
    String? msRegion,
    String? msLang,
    String? msVoice,
    bool? useTestProxy,
    String? testProxyHost,
    String? testProxyPort,
  }) async {
    setLoadingState(true);
    String testText = "Test";
    if (provider == TTSProvider.microsoft &&
        msLang != null &&
        msLang.toLowerCase().startsWith('zh')) {
      testText = "测试";
    }

    http.Client testClient = _getHttpClient(
      useDialogProxy: useTestProxy,
      dialogProxyHost: testProxyHost,
      dialogProxyPort: testProxyPort,
    );

    http.Response? response;
    String testError = '';

    try {
      if (provider == TTSProvider.openai) {
        if (openAIApiKey == null || openAIApiKey.isEmpty) {
          testError = "OpenAI API Key 未提供。(OpenAI API Key not provided.)";
        } else {
          response = await testClient.post(
            Uri.parse('https://api.openai.com/v1/audio/speech'),
            headers: {
              'Authorization': 'Bearer $openAIApiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model':
                  openAIModel ?? _MyHomePageState._defaultOpenAIModelSettings,
              'input': testText,
              'voice':
                  openAIVoice ?? _MyHomePageState._defaultOpenAIVoiceSettings,
              'response_format': 'mp3',
            }),
          );
        }
      } else {
        // Microsoft TTS
        if (msKey == null ||
            msKey.isEmpty ||
            msRegion == null ||
            msRegion.isEmpty) {
          testError =
              "Microsoft Key 或 Region 未提供。(Microsoft Key or Region not provided.)";
        } else {
          String effectiveMsVoice =
              msVoice ??
              _getMicrosoftDefaultVoiceForLanguage(
                msLang ?? _MyHomePageState._defaultMsLanguage,
              );
          if (effectiveMsVoice.isEmpty &&
              _msHardcodedVoicesByLanguage.containsKey(
                msLang ?? _MyHomePageState._defaultMsLanguage,
              )) {
            effectiveMsVoice =
                _msHardcodedVoicesByLanguage[msLang ??
                        _MyHomePageState._defaultMsLanguage]!
                    .first;
          }
          if (effectiveMsVoice.isEmpty) {
            effectiveMsVoice = _getMicrosoftDefaultVoiceForLanguage('en-US');
          }

          String ssml = """
              <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='${msLang ?? _MyHomePageState._defaultMsLanguage}'>
                  <voice name='$effectiveMsVoice'>
                      ${_escapeXml(testText)}
                  </voice>
              </speak>
          """;
          response = await testClient.post(
            Uri.parse(
              'https://$msRegion.tts.speech.microsoft.com/cognitiveservices/v1',
            ),
            headers: {
              'Ocp-Apim-Subscription-Key': msKey,
              'Content-Type': 'application/ssml+xml',
              'X-Microsoft-OutputFormat': 'audio-16khz-128kbitrate-mono-mp3',
              'User-Agent': 'FlutterTTSAppTest',
            },
            body: ssml,
          );
        }
      }
    } catch (e) {
      testError = "测试请求失败: $e (Test request failed: $e)";
    } finally {
      if (testClient is IOClient) {
        testClient.close();
      } else if (testClient is http.Client && testClient != http.Client()) {
        // Standard http.Client.close() is a no-op.
      }
    }

    setLoadingState(false);
    if (!mounted) return;

    if (testError.isNotEmpty) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        SnackBar(content: Text(testError), backgroundColor: Colors.red),
      );
      return;
    }

    if (response != null) {
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text('配置有效！(Configuration is valid!)'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        final String errorMessage = _parseErrorFromResponse(response);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          SnackBar(
            content: Text(
              '测试失败: ${response.statusCode} - $errorMessage (Test failed)',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else if (testError.isEmpty) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(
          content: Text(
            '测试请求未能完成，请检查配置。(Test request could not be completed, please check configuration.)',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  List<Widget> _buildOpenAISettingsUI(
    StateSetter setDialogState,
    TextEditingController apiKeyController,
    String currentModel,
    String currentVoice,
    bool isTesting,
    Function(String) onModelChanged,
    Function(String) onVoiceChanged,
    VoidCallback onTestPressed,
  ) {
    return [
      TextField(
        controller: apiKeyController,
        decoration: InputDecoration(
          labelText: _tr('openAIApiKeyLabel'),
          border: OutlineInputBorder(),
          hintText: _tr('openAIApiKeyHint'),
        ),
        obscureText: true,
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        value: currentModel,
        decoration: InputDecoration(
          labelText: _tr('openAIModelLabel'),
          border: OutlineInputBorder(),
        ),
        items:
            _openAIModels.map((String model) {
              return DropdownMenuItem<String>(value: model, child: Text(model));
            }).toList(),
        onChanged: (String? newValue) {
          if (newValue != null) {
            onModelChanged(newValue);
          }
        },
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        value: currentVoice,
        decoration: InputDecoration(
          labelText: _tr('openAIVoiceLabel'),
          border: OutlineInputBorder(),
        ),
        items:
            _openAIVoices.map((String voice) {
              return DropdownMenuItem<String>(value: voice, child: Text(voice));
            }).toList(),
        onChanged: (String? newValue) {
          if (newValue != null) {
            onVoiceChanged(newValue);
          }
        },
      ),
      const SizedBox(height: 8),
      ElevatedButton.icon(
        icon:
            isTesting
                ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.verified_user_outlined),
        label: Text(_tr('testOpenAIConfigButton')),
        onPressed: isTesting ? null : onTestPressed,
      ),
    ];
  }

  List<Widget> _buildMicrosoftSettingsUI(
    StateSetter setDialogState,
    TextEditingController subKeyController,
    TextEditingController regionController,
    String currentLanguage,
    String currentVoice,
    bool isFetchingVoices,
    bool isTesting,
    Function(String) onLanguageChanged,
    Function(String) onVoiceChanged,
    VoidCallback onRefreshVoices,
    VoidCallback onTestPressed,
  ) {
    List<String> voicesForSelectedLang =
        _dynamicMsVoicesByLanguage[currentLanguage] ??
        _msHardcodedVoicesByLanguage[currentLanguage] ??
        [];
    if (voicesForSelectedLang.isEmpty &&
        _msHardcodedVoicesByLanguage.containsKey(currentLanguage)) {
      voicesForSelectedLang = _msHardcodedVoicesByLanguage[currentLanguage]!;
    }
    String effectiveCurrentVoice = currentVoice;
    if (voicesForSelectedLang.isNotEmpty &&
        !voicesForSelectedLang.contains(currentVoice)) {
      effectiveCurrentVoice = voicesForSelectedLang.first;
    } else if (voicesForSelectedLang.isEmpty) {
      effectiveCurrentVoice = '';
    }

    return [
      TextField(
        controller: subKeyController,
        decoration: InputDecoration(
          labelText: _tr('msSubKeyLabel'),
          border: OutlineInputBorder(),
        ),
        obscureText: true,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: regionController,
        decoration: InputDecoration(
          labelText: _tr('msRegionLabel'),
          border: OutlineInputBorder(),
          hintText: _tr('msRegionHint'),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: currentLanguage,
              decoration: InputDecoration(
                labelText: _tr('msLanguageLabel'),
                border: OutlineInputBorder(),
              ),
              items:
                  (_dynamicMsVoicesByLanguage.keys.isNotEmpty
                          ? _dynamicMsVoicesByLanguage.keys.toList()
                          : _msHardcodedVoicesByLanguage.keys.toList())
                      .map((String langCode) {
                        return DropdownMenuItem<String>(
                          value: langCode,
                          child: Text(langCode),
                        );
                      })
                      .toList(),
              onChanged: (String? newValue) {
                if (newValue != null) {
                  onLanguageChanged(newValue);
                }
              },
            ),
          ),
          IconButton(
            icon:
                isFetchingVoices
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.refresh),
            tooltip: _tr('refreshVoiceListTooltip'),
            onPressed: isFetchingVoices ? null : onRefreshVoices,
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (voicesForSelectedLang.isNotEmpty)
        DropdownButtonFormField<String>(
          value: effectiveCurrentVoice,
          decoration: InputDecoration(
            labelText: _tr('msVoiceNameLabel'),
            border: OutlineInputBorder(),
          ),
          items:
              voicesForSelectedLang.map((String voiceName) {
                return DropdownMenuItem<String>(
                  value: voiceName,
                  child: Text(voiceName),
                );
              }).toList(),
          onChanged: (String? newValue) {
            if (newValue != null) {
              onVoiceChanged(newValue);
            }
          },
        )
      else
        Text(
          _tr('msVoiceNotAvailable'),
          style: TextStyle(color: Colors.orange),
        ),
      const SizedBox(height: 8),
      ElevatedButton.icon(
        icon:
            isTesting
                ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.verified_user_outlined),
        label: Text(_tr('testMSConfigButton')),
        onPressed: isTesting ? null : onTestPressed,
      ),
    ];
  }

  void _showSettingsDialog() {
    TTSProvider dialogTTSProvider = _selectedTTSProvider;
    final dialogOpenAIApiKeyController = TextEditingController(text: _apiKey);
    final dialogMsSubKeyController = TextEditingController(
      text: _msSubscriptionKey,
    );
    final dialogMsRegionController = TextEditingController(text: _msRegion);
    String dialogMsSelectedLanguage = _msSelectedLanguage;
    String dialogMsSelectedVoice = _msSelectedVoiceName;

    String localDialogSelectedOpenAIModel = _selectedModel;
    String localDialogSelectedOpenAIVoice = _selectedVoice;
    bool dialogUseProxy = _useProxy;
    final dialogProxyHostController = TextEditingController(text: _proxyHost);
    final dialogProxyPortController = TextEditingController(text: _proxyPort);
    final dialogMaxCharsController = TextEditingController(
      text: _maxCharsPerRequest.toString(),
    );
    final dialogPrefetchCountController = TextEditingController(
      text: _prefetchChunkCount.toString(),
    );
    ReadingTheme dialogReadingTheme = _currentReadingTheme;
    Locale dialogSelectedLocale = _selectedLocale;
    bool isTestingConfig = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            List<Widget> providerSettingsWidgets;
            if (dialogTTSProvider == TTSProvider.openai) {
              providerSettingsWidgets = _buildOpenAISettingsUI(
                setDialogState,
                dialogOpenAIApiKeyController,
                localDialogSelectedOpenAIModel,
                localDialogSelectedOpenAIVoice,
                isTestingConfig,
                (newModel) => setDialogState(
                  () => localDialogSelectedOpenAIModel = newModel,
                ),
                (newVoice) => setDialogState(
                  () => localDialogSelectedOpenAIVoice = newVoice,
                ),
                () => _testTTSConfiguration(
                  dialogContext,
                  (loading) => setDialogState(() => isTestingConfig = loading),
                  provider: TTSProvider.openai,
                  openAIApiKey: dialogOpenAIApiKeyController.text,
                  openAIModel: localDialogSelectedOpenAIModel,
                  openAIVoice: localDialogSelectedOpenAIVoice,
                  useTestProxy: dialogUseProxy,
                  testProxyHost: dialogProxyHostController.text,
                  testProxyPort: dialogProxyPortController.text,
                ),
              );
            } else {
              // Microsoft TTS
              providerSettingsWidgets = _buildMicrosoftSettingsUI(
                setDialogState,
                dialogMsSubKeyController,
                dialogMsRegionController,
                dialogMsSelectedLanguage,
                dialogMsSelectedVoice,
                _isFetchingMsVoices,
                // Use state variable for fetching voices
                isTestingConfig,
                (newLang) => setDialogState(() {
                  dialogMsSelectedLanguage = newLang;
                  List<String> voicesForNewLang =
                      _dynamicMsVoicesByLanguage[newLang] ??
                      _msHardcodedVoicesByLanguage[newLang] ??
                      [];
                  dialogMsSelectedVoice =
                      voicesForNewLang.isNotEmpty ? voicesForNewLang.first : '';
                }),
                (newVoice) =>
                    setDialogState(() => dialogMsSelectedVoice = newVoice),
                () async {
                  setDialogState(() => _isFetchingMsVoices = true);
                  await _fetchMicrosoftVoices(
                    dialogMsRegionController.text,
                    dialogMsSubKeyController.text,
                    setLoadingInDialog:
                        (loading) =>
                            setDialogState(() => _isFetchingMsVoices = loading),
                  );
                  List<String> voicesForLang =
                      _dynamicMsVoicesByLanguage[dialogMsSelectedLanguage] ??
                      _msHardcodedVoicesByLanguage[dialogMsSelectedLanguage] ??
                      [];
                  setDialogState(() {
                    dialogMsSelectedVoice =
                        voicesForLang.isNotEmpty ? voicesForLang.first : '';
                  });
                },
                () => _testTTSConfiguration(
                  dialogContext,
                  (loading) => setDialogState(() => isTestingConfig = loading),
                  provider: TTSProvider.microsoft,
                  msKey: dialogMsSubKeyController.text,
                  msRegion: dialogMsRegionController.text,
                  msLang: dialogMsSelectedLanguage,
                  msVoice: dialogMsSelectedVoice,
                  useTestProxy: dialogUseProxy,
                  testProxyHost: dialogProxyHostController.text,
                  testProxyPort: dialogProxyPortController.text,
                ),
              );
            }

            return AlertDialog(
              title: Text(_tr('settingsTitle')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    DropdownButtonFormField<Locale>(
                      value: dialogSelectedLocale,
                      decoration: InputDecoration(
                        labelText: _tr('interfaceLanguageLabel'),
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: Locale('zh'),
                          child: Text('中文'),
                        ),
                        DropdownMenuItem(
                          value: Locale('en'),
                          child: Text('English'),
                        ),
                      ],
                      onChanged: (Locale? newValue) {
                        if (newValue != null) {
                          setDialogState(() {
                            dialogSelectedLocale = newValue;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<TTSProvider>(
                      value: dialogTTSProvider,
                      decoration: InputDecoration(
                        labelText: _tr('ttsProviderLabel'),
                        border: OutlineInputBorder(),
                      ),
                      items:
                          TTSProvider.values.map((TTSProvider provider) {
                            return DropdownMenuItem<TTSProvider>(
                              value: provider,
                              child: Text(
                                provider == TTSProvider.openai
                                    ? 'OpenAI'
                                    : 'Microsoft Azure',
                              ),
                            );
                          }).toList(),
                      onChanged: (TTSProvider? newValue) {
                        if (newValue != null) {
                          setDialogState(() {
                            dialogTTSProvider = newValue;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    ...providerSettingsWidgets,
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: dialogMaxCharsController,
                      decoration: InputDecoration(
                        labelText: _tr('maxCharsLabel'),
                        border: OutlineInputBorder(),
                        hintText: _tr('maxCharsHint'),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value == null || value.isEmpty)
                          return '不能为空 (Cannot be empty)';
                        final n = int.tryParse(value);
                        if (n == null) return '请输入数字 (Please enter a number)';
                        if (n <= 0) return '必须大于0 (Must be > 0)';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: dialogPrefetchCountController,
                      decoration: InputDecoration(
                        labelText: _tr('prefetchChunksLabel'),
                        border: OutlineInputBorder(),
                        hintText: _tr('prefetchChunksHint'),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value == null || value.isEmpty)
                          return '不能为空 (Cannot be empty)';
                        final n = int.tryParse(value);
                        if (n == null) return '请输入数字 (Please enter a number)';
                        if (n < 1) return '至少为1 (Must be at least 1)';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: Text(_tr('useProxyLabel')),
                      value: dialogUseProxy,
                      onChanged: (bool value) {
                        setDialogState(() {
                          dialogUseProxy = value;
                          if (dialogUseProxy) {
                            if (dialogProxyHostController.text.isEmpty) {
                              dialogProxyHostController.text =
                                  _defaultProxyHostSettings;
                            }
                            if (dialogProxyPortController.text.isEmpty) {
                              dialogProxyPortController.text =
                                  _defaultProxyPortSettings;
                            }
                          }
                        });
                      },
                      activeColor: Theme.of(context).colorScheme.primary,
                    ),
                    if (dialogUseProxy) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: dialogProxyHostController,
                        decoration: InputDecoration(
                          labelText: _tr('proxyHostLabel'),
                          border: OutlineInputBorder(),
                          hintText: _defaultProxyHostSettings,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: dialogProxyPortController,
                        decoration: InputDecoration(
                          labelText: _tr('proxyPortLabel'),
                          border: OutlineInputBorder(),
                          hintText: _defaultProxyPortSettings,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Divider(),
                    Text(
                      _tr('readingThemeLabel'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    DropdownButtonFormField<String>(
                      value:
                          _predefinedThemes.entries
                              .firstWhere(
                                (entry) =>
                                    entry.value.backgroundColor ==
                                        dialogReadingTheme.backgroundColor &&
                                    entry.value.textColor ==
                                        dialogReadingTheme.textColor,
                                orElse: () => _predefinedThemes.entries.first,
                              )
                              .key, // Find current theme name
                      decoration: InputDecoration(
                        labelText: _tr('selectPresetThemeLabel'),
                        border: OutlineInputBorder(),
                      ),
                      items:
                          _predefinedThemes.keys.map((String key) {
                            return DropdownMenuItem<String>(
                              value: key,
                              child: Text(key),
                            );
                          }).toList(),
                      onChanged: (String? newKey) {
                        if (newKey != null &&
                            _predefinedThemes.containsKey(newKey)) {
                          setDialogState(() {
                            dialogReadingTheme = _predefinedThemes[newKey]!;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.save_alt),
                      title: Text(_tr('saveCurrentConfigButton')),
                      onTap: () {
                        _showSaveProfileDialog();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.folder_open_outlined),
                      title: Text(_tr('loadManageConfigButton')),
                      onTap: () {
                        _showProfilesDialog();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: Text(_tr('viewClearLogsButton')),
                      onTap: () {
                        _showErrorLogsDialog();
                      },
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: Text(_tr('resetActiveSettingsButton')),
                  onPressed: () async {
                    await _resetSettingsToDefaults();
                    setDialogState(() {
                      dialogTTSProvider = _selectedTTSProvider;
                      dialogOpenAIApiKeyController.text = _apiKey;
                      dialogMsSubKeyController.text = _msSubscriptionKey;
                      dialogMsRegionController.text = _msRegion;
                      dialogMsSelectedLanguage = _msSelectedLanguage;
                      dialogMsSelectedVoice = _msSelectedVoiceName;
                      localDialogSelectedOpenAIModel = _selectedModel;
                      localDialogSelectedOpenAIVoice = _selectedVoice;
                      dialogUseProxy = _useProxy;
                      dialogProxyHostController.text = _proxyHost;
                      dialogProxyPortController.text = _proxyPort;
                      dialogMaxCharsController.text =
                          _maxCharsPerRequest.toString();
                      dialogPrefetchCountController.text =
                          _prefetchChunkCount.toString();
                      dialogReadingTheme = _currentReadingTheme;
                      dialogSelectedLocale = _selectedLocale;
                    });
                  },
                ),
                TextButton(
                  child: Text(_tr('cancelButton')),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                ElevatedButton(
                  child: Text(_tr('applyButton')),
                  onPressed: () {
                    final int maxChars =
                        int.tryParse(dialogMaxCharsController.text) ??
                        _maxCharsPerRequest;
                    final int prefetchCount =
                        int.tryParse(dialogPrefetchCountController.text) ??
                        _MyHomePageState._defaultPrefetchChunkCountSettings;

                    _saveSettingsDialogValues(
                      ttsProvider: dialogTTSProvider,
                      openAIApiKey: dialogOpenAIApiKeyController.text,
                      msSubscriptionKey: dialogMsSubKeyController.text,
                      msRegion: dialogMsRegionController.text,
                      msLanguage: dialogMsSelectedLanguage,
                      msVoiceName: dialogMsSelectedVoice,
                      model: localDialogSelectedOpenAIModel,
                      voice: localDialogSelectedOpenAIVoice,
                      useProxy: dialogUseProxy,
                      proxyHost: dialogProxyHostController.text,
                      proxyPort: dialogProxyPortController.text,
                      maxChars:
                          maxChars > 0
                              ? maxChars
                              : _defaultMaxCharsPerRequestSettings,
                      prefetchCount:
                          prefetchCount >= 1
                              ? prefetchCount
                              : _defaultPrefetchChunkCountSettings,
                      readingTheme: dialogReadingTheme,
                      appLocale: dialogSelectedLocale,
                    );
                    Navigator.of(context).pop();
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showPlaybackSpeedDialog() {
    final TextEditingController dialogSpeedController = TextEditingController(
      text: _playbackSpeed.toStringAsFixed(2),
    );
    double tempSpeed = _playbackSpeed;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(_tr('playbackSpeedDialogTitle')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_tr('currentSpeedLabel')}: ${tempSpeed.toStringAsFixed(2)}x',
                  ),
                  Slider(
                    value: tempSpeed,
                    min: _minPlaybackSpeed,
                    max: _maxPlaybackSpeed,
                    divisions:
                        ((_maxPlaybackSpeed - _minPlaybackSpeed) / 0.05)
                            .round(),
                    label: tempSpeed.toStringAsFixed(2),
                    onChanged: (value) {
                      setDialogState(() {
                        tempSpeed = value;
                        dialogSpeedController.text = tempSpeed.toStringAsFixed(
                          2,
                        );
                      });
                    },
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: dialogSpeedController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                      textAlign: TextAlign.center,
                      onChanged: (value) {
                        final speed = double.tryParse(value);
                        if (speed != null) {
                          setDialogState(() {
                            tempSpeed = speed.clamp(
                              _minPlaybackSpeed,
                              _maxPlaybackSpeed,
                            );
                          });
                        }
                      },
                      onSubmitted: (value) {
                        final speed = double.tryParse(value);
                        if (speed != null) {
                          _setPlaybackSpeed(
                            speed.clamp(_minPlaybackSpeed, _maxPlaybackSpeed),
                          );
                        } else {
                          dialogSpeedController.text = tempSpeed
                              .toStringAsFixed(2);
                        }
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_tr('cancelButton')),
                ),
                ElevatedButton(
                  onPressed: () {
                    final speed = double.tryParse(dialogSpeedController.text);
                    if (speed != null) {
                      _setPlaybackSpeed(
                        speed.clamp(_minPlaybackSpeed, _maxPlaybackSpeed),
                      );
                    } else {
                      _setPlaybackSpeed(tempSpeed);
                    }
                    Navigator.of(context).pop();
                  },
                  child: Text(_tr('applyButton')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showVolumeDialog() {
    final TextEditingController dialogVolumeController = TextEditingController(
      text: (_volume * 100).toStringAsFixed(0),
    );
    double tempVolume = _volume;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(_tr('volumeDialogTitle')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_tr('currentVolumeLabel')}: ${(tempVolume * 100).toStringAsFixed(0)}%',
                  ),
                  Slider(
                    value: tempVolume,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    // 0.05 increments
                    label: (tempVolume * 100).toStringAsFixed(0),
                    onChanged: (value) {
                      setDialogState(() {
                        tempVolume = value;
                        dialogVolumeController.text = (tempVolume * 100)
                            .toStringAsFixed(0);
                      });
                    },
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: dialogVolumeController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                        suffixText: '%',
                      ),
                      textAlign: TextAlign.center,
                      onChanged: (value) {
                        final volumePercent = double.tryParse(value);
                        if (volumePercent != null) {
                          setDialogState(() {
                            tempVolume = (volumePercent / 100).clamp(0.0, 1.0);
                          });
                        }
                      },
                      onSubmitted: (value) {
                        final volumePercent = double.tryParse(value);
                        if (volumePercent != null) {
                          _setVolume((volumePercent / 100).clamp(0.0, 1.0));
                        } else {
                          dialogVolumeController.text = (tempVolume * 100)
                              .toStringAsFixed(0);
                        }
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_tr('cancelButton')),
                ),
                ElevatedButton(
                  onPressed: () {
                    final volumePercent = double.tryParse(
                      dialogVolumeController.text,
                    );
                    if (volumePercent != null) {
                      _setVolume((volumePercent / 100).clamp(0.0, 1.0));
                    } else {
                      _setVolume(tempVolume);
                    }
                    Navigator.of(context).pop();
                  },
                  child: Text(_tr('applyButton')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showTextInputDialog() {
    final TextEditingController dialogInputController = TextEditingController(
      text: _mainTextHolderController.text,
    );
    bool isLoadingFile = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(_tr('inputDialogTitle')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: dialogInputController,
                      decoration: InputDecoration(
                        labelText: _tr('inputDialogLabel'),
                        hintText: _tr('inputDialogHint'),
                        border: const OutlineInputBorder(),
                        suffixIcon:
                            dialogInputController.text.isNotEmpty
                                ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed:
                                      () => setDialogState(
                                        () => dialogInputController.clear(),
                                      ),
                                )
                                : null,
                      ),
                      maxLines: 8,
                      minLines: 3,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon:
                          isLoadingFile
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.file_upload_outlined),
                      label: Text(_tr('loadFromFileButton')),
                      onPressed:
                          isLoadingFile
                              ? null
                              : () async {
                                setDialogState(() => isLoadingFile = true);
                                FilePickerResult? result = await FilePicker
                                    .platform
                                    .pickFiles(
                                      type: FileType.custom,
                                      allowedExtensions: [
                                        'txt',
                                        'epub',
                                        'mobi',
                                        'azw3',
                                      ],
                                    );
                                if (result != null &&
                                    result.files.single.path != null) {
                                  try {
                                    String content = await compute(
                                      _readFileContentInBackground,
                                      {
                                        'filePath': result.files.single.path!,
                                        'encodingName': 'UTF-8',
                                        // Default to UTF-8 for TXT, EPUB parser handles its own.
                                      },
                                    );
                                    setDialogState(() {
                                      dialogInputController.text = content;
                                    });
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '读取或解码文件失败 (Failed to read or decode file): $e',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                }
                                setDialogState(() => isLoadingFile = false);
                              },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_tr('cancelButton')),
                ),
                ElevatedButton(
                  onPressed: () {
                    final newText = dialogInputController.text;
                    if (_mainTextHolderController.text != newText) {
                      if (_isCurrentlyPlaying() ||
                          _isLoading ||
                          _processedTextChunks.isNotEmpty) {
                        _stopPlayback();
                      }
                      _mainTextHolderController.text = newText;
                      _prefs.setString('main_text_content', newText);
                      if (mounted) {
                        setState(() {
                          _currentTextForDisplay = "";
                          _processedTextChunks = [];
                          _chunkKeys = [];
                          _currentlyPlayingChunkIndex = -1;
                          _highlightedCharacterInChunkIndex = -1;
                          _bookmarks.clear();
                          _saveBookmarks();
                        });
                      }
                    }
                    Navigator.of(context).pop();
                  },
                  child: Text(_tr('applyTextButton')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _toggleBookmark(int chunkStartIndex, {bool autoAddOnly = false}) {
    setState(() {
      if (autoAddOnly) {
        if (!_bookmarks.contains(chunkStartIndex)) {
          _bookmarks.add(chunkStartIndex);
          _bookmarks.sort();
          _saveBookmarks();
        }
      } else {
        // Toggle behavior
        if (_bookmarks.contains(chunkStartIndex)) {
          _bookmarks.remove(chunkStartIndex);
        } else {
          _bookmarks.add(chunkStartIndex);
          _bookmarks.sort();
        }
        _saveBookmarks();
      }
    });
  }

  void _showBookmarksDialog() {
    showDialog(
      context: context,
      builder: (context) {
        if (_bookmarks.isEmpty) {
          return AlertDialog(
            title: Text(_tr('bookmarksDialogTitle')),
            content: Text(_tr('noBookmarks')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_tr('closeButton')),
              ),
            ],
          );
        }

        List<Widget> bookmarkTiles = [];
        for (int bookmarkedStartIndex in _bookmarks) {
          int chunkIndex = _processedTextChunks.indexWhere(
            (chunk) => chunk['startIndex'] == bookmarkedStartIndex,
          );
          if (chunkIndex != -1) {
            final chunkData = _processedTextChunks[chunkIndex];
            final chunkText = chunkData['text'] as String;
            bookmarkTiles.add(
              ListTile(
                title: Text(_truncateText(chunkText, 50)),
                leading: Icon(
                  Icons.bookmark,
                  color: Theme.of(context).colorScheme.primary,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: _tr('deleteBookmarkTooltip'),
                  onPressed: () {
                    _toggleBookmark(bookmarkedStartIndex);
                    Navigator.of(context).pop();
                    _showBookmarksDialog();
                  },
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _handleChunkTap(chunkIndex, fromBookmark: true);
                },
              ),
            );
          }
        }

        return AlertDialog(
          title: Text(_tr('bookmarksDialogTitle')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children:
                  bookmarkTiles.isNotEmpty
                      ? bookmarkTiles
                      : [Center(child: Text(_tr('noBookmarksForText')))],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_tr('closeButton')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleChunkTap(
    int tappedChunkDisplayIndex, {
    bool fromBookmark = false,
  }) async {
    if (!mounted) return;

    if (_isCurrentlyPlaying() || _isLoading) {
      await _stopPlayback();
    }

    final String currentText = _mainTextHolderController.text;
    if (_processedTextChunks.isEmpty && currentText.isNotEmpty) {
      setState(() {
        _currentTextForDisplay = currentText;
        _processedTextChunks = _splitTextIntoDetailedChunks(
          _currentTextForDisplay,
          _maxCharsPerRequest,
        );
        _chunkKeys = List.generate(
          _processedTextChunks.length,
          (_) => GlobalKey(),
        );
        _highlightedCharacterInChunkIndex = -1;
      });
      if (_processedTextChunks.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '文本为空或处理失败，无法跳转。(Text is empty or processing failed, cannot jump.)',
              ),
            ),
          );
        return;
      }
    }

    if (tappedChunkDisplayIndex < 0 ||
        tappedChunkDisplayIndex >= _processedTextChunks.length) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('无效的文本片段索引。(Invalid text chunk index.)'),
          ),
        );
      }
      return;
    }

    await _initiatePlaybackFromIndex(tappedChunkDisplayIndex);
  }

  String _truncateText(String text, int maxLength) {
    if (text.length <= maxLength) {
      return text;
    }
    return '${text.substring(0, maxLength)}...';
  }

  // --- Profile Management Methods ---
  Future<void> _saveCurrentSettingsAsProfile(String profileName) async {
    if (profileName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('配置文件名不能为空。(Profile name cannot be empty.)'),
        ),
      );
      return;
    }
    if (_savedProfiles.containsKey(profileName)) {
      bool overwrite =
          await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: Text(_tr('confirmOverwriteTitle')),
                  content: Text(
                    _tr(
                      'confirmOverwriteMessage',
                      params: {'profileName': profileName},
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(_tr('noButton')),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(_tr('yesButton')),
                    ),
                  ],
                ),
          ) ??
          false;
      if (!overwrite) return;
    }

    Map<String, dynamic> currentProfileData = {
      'ttsProvider': _selectedTTSProvider.index,
      'apiKey': _apiKey,
      'msSubscriptionKey': _msSubscriptionKey,
      'msRegion': _msRegion,
      'msLanguage': _msSelectedLanguage,
      'msVoiceName': _msSelectedVoiceName,
      'selectedModel': _selectedModel,
      // OpenAI model
      'selectedVoice': _selectedVoice,
      // OpenAI voice
      'useProxy': _useProxy,
      'proxyHost': _proxyHost,
      'proxyPort': _proxyPort,
      'playbackSpeed': _playbackSpeed,
      'maxCharsPerRequest': _maxCharsPerRequest,
      'prefetchChunkCount': _prefetchChunkCount,
      // 'mainTextContent': _mainTextHolderController.text, // Do not save main text in profile
      'bookmarks': _bookmarks.map((b) => b.toString()).toList(),
      'readingTheme': _currentReadingTheme.toJson(),
      'appLocale': _selectedLocale.languageCode,
    };

    _savedProfiles[profileName] = jsonEncode(currentProfileData);
    await _prefs.setString(_profilesKey, jsonEncode(_savedProfiles));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '配置 "$profileName" 已保存。(Profile "$profileName" saved.)',
          ),
        ),
      );
      setState(() {});
    }
  }

  Future<void> _applyProfileSettings(Map<String, dynamic> profileData) async {
    await _stopPlayback();

    _selectedTTSProvider =
        TTSProvider.values[profileData['ttsProvider'] ??
            TTSProvider.openai.index];
    _apiKey = profileData['apiKey'] ?? '';
    _msSubscriptionKey = profileData['msSubscriptionKey'] ?? '';
    _msRegion = profileData['msRegion'] ?? _defaultMsRegionSettings;
    _msSelectedLanguage = profileData['msLanguage'] ?? _defaultMsLanguage;
    _msSelectedVoiceName =
        profileData['msVoiceName'] ??
        (_msHardcodedVoicesByLanguage[_msSelectedLanguage]?.first ?? '');

    _selectedModel =
        profileData['selectedModel'] ??
        _MyHomePageState._defaultOpenAIModelSettings;
    _selectedVoice =
        profileData['selectedVoice'] ??
        _MyHomePageState._defaultOpenAIVoiceSettings;
    _useProxy =
        profileData['useProxy'] ?? _MyHomePageState._defaultUseProxySettings;
    _proxyHost =
        profileData['proxyHost'] ?? _MyHomePageState._defaultProxyHostSettings;
    _proxyPort =
        profileData['proxyPort'] ?? _MyHomePageState._defaultProxyPortSettings;
    _playbackSpeed =
        profileData['playbackSpeed'] ??
        _MyHomePageState._defaultPlaybackSpeedSettings;
    _maxCharsPerRequest =
        profileData['maxCharsPerRequest'] ??
        _MyHomePageState._defaultMaxCharsPerRequestSettings;
    _prefetchChunkCount =
        profileData['prefetchChunkCount'] ??
        _MyHomePageState._defaultPrefetchChunkCountSettings;
    // _mainTextHolderController.text = profileData['mainTextContent'] ?? ''; // Do not load main text from profile

    List<dynamic> loadedBookmarksDynamic = profileData['bookmarks'] ?? [];
    _bookmarks =
        loadedBookmarksDynamic
            .map((b) => int.tryParse(b.toString()) ?? -1)
            .where((i) => i != -1)
            .toList();

    if (profileData['readingTheme'] != null) {
      try {
        _currentReadingTheme = ReadingTheme.fromJson(
          profileData['readingTheme'] as Map<String, dynamic>,
        );
      } catch (_) {
        _currentReadingTheme = _defaultReadingTheme;
      }
    } else {
      _currentReadingTheme = _defaultReadingTheme;
    }
    _selectedLocale = Locale(profileData['appLocale'] ?? 'zh');

    await _persistCurrentActiveSettings(); // Save loaded profile as current active settings, excluding mainTextContent
    if (Platform.isWindows) {
      await _windowsAudioPlayer.setPlaybackRate(_playbackSpeed);
    } else {
      await _justAudioPlayer.setSpeed(_playbackSpeed);
    }

    _currentTextForDisplay = "";
    _processedTextChunks = [];
    _chunkKeys = [];
    _currentlyPlayingChunkIndex = -1;
    _highlightedCharacterInChunkIndex = -1;

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已加载并应用。(Profile loaded and applied.)')),
      );
    }
  }

  Future<void> _loadProfile(String profileName) async {
    String? profileJson = _savedProfiles[profileName];
    if (profileJson != null) {
      try {
        Map<String, dynamic> profileData = jsonDecode(profileJson);
        await _applyProfileSettings(profileData);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '加载配置 "$profileName" 失败: $e (Failed to load profile "$profileName": $e)',
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _deleteProfile(String profileName) async {
    bool confirmDelete =
        await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: Text(_tr('confirmDeleteTitle')),
                content: Text(
                  _tr(
                    'confirmDeleteMessage',
                    params: {'profileName': profileName},
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(_tr('cancelButton')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(_tr('deleteButton')),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ],
              ),
        ) ??
        false;

    if (confirmDelete) {
      _savedProfiles.remove(profileName);
      await _prefs.setString(_profilesKey, jsonEncode(_savedProfiles));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '配置 "$profileName" 已删除。(Profile "$profileName" deleted.)',
            ),
          ),
        );
        setState(() {});
      }
    }
  }

  void _showSaveProfileDialog() {
    final TextEditingController profileNameController = TextEditingController();
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(_tr('saveProfileTitle')),
            content: TextField(
              controller: profileNameController,
              decoration: InputDecoration(hintText: _tr('profileNameHint')),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_tr('cancelButton')),
              ),
              ElevatedButton(
                onPressed: () {
                  _saveCurrentSettingsAsProfile(profileNameController.text);
                  Navigator.of(context).pop();
                },
                child: Text(_tr('saveButton')),
              ),
            ],
          ),
    );
  }

  void _showProfilesDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(_tr('loadProfileTitle')),
              content: SizedBox(
                width: double.maxFinite,
                child:
                    _savedProfiles.isEmpty
                        ? Center(child: Text(_tr('noSavedProfiles')))
                        : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _savedProfiles.length,
                          itemBuilder: (context, index) {
                            String profileName = _savedProfiles.keys.elementAt(
                              index,
                            );
                            return ListTile(
                              title: Text(profileName),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    // Export Button
                                    icon: const Icon(
                                      Icons.upload_file_outlined,
                                      color: Colors.blue,
                                    ),
                                    tooltip: _tr('exportProfileTooltip'),
                                    onPressed: () async {
                                      String? filePath = await FilePicker
                                          .platform
                                          .saveFile(
                                            dialogTitle:
                                                '保存配置文件 (Save Profile As)',
                                            fileName: '$profileName.json',
                                            allowedExtensions: ['json'],
                                            type: FileType.custom,
                                          );
                                      if (filePath != null) {
                                        try {
                                          final file = File(filePath);
                                          await file.writeAsString(
                                            _savedProfiles[profileName]!,
                                          );
                                          if (mounted)
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '配置已导出到: $filePath (Profile exported to: $filePath)',
                                                ),
                                              ),
                                            );
                                        } catch (e) {
                                          if (mounted)
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '导出失败 (Export failed): $e',
                                                ),
                                              ),
                                            );
                                        }
                                      }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.file_download_outlined,
                                      color: Colors.green,
                                    ),
                                    tooltip: _tr('loadProfileTooltip'),
                                    onPressed: () async {
                                      await _loadProfile(profileName);
                                      Navigator.of(context).pop();
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    tooltip: _tr('deleteProfileTooltip'),
                                    onPressed: () async {
                                      await _deleteProfile(profileName);
                                      setDialogState(() {});
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
              ),
              actions: <Widget>[
                ElevatedButton.icon(
                  // Import Button
                  icon: const Icon(Icons.download_outlined),
                  label: Text(_tr('importProfileButton')),
                  onPressed: () async {
                    FilePickerResult? result = await FilePicker.platform
                        .pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['json'],
                        );
                    if (result != null && result.files.single.path != null) {
                      try {
                        final file = File(result.files.single.path!);
                        String fileContent = await file.readAsString();

                        final TextEditingController importNameController =
                            TextEditingController(
                              text: result.files.single.name.replaceAll(
                                '.json',
                                '',
                              ),
                            );
                        bool? confirmImport = await showDialog<bool>(
                          context: context,
                          builder:
                              (nameDialogContext) => AlertDialog(
                                title: Text(_tr('importProfileButton')),
                                content: TextField(
                                  controller: importNameController,
                                  decoration: InputDecoration(
                                    labelText: _tr('nameThisProfileLabel'),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed:
                                        () => Navigator.of(
                                          nameDialogContext,
                                        ).pop(false),
                                    child: Text(_tr('cancelButton')),
                                  ),
                                  ElevatedButton(
                                    onPressed:
                                        () => Navigator.of(
                                          nameDialogContext,
                                        ).pop(true),
                                    child: Text(_tr('importButton')),
                                  ),
                                ],
                              ),
                        );

                        if (confirmImport == true &&
                            importNameController.text.isNotEmpty) {
                          _savedProfiles[importNameController.text] =
                              fileContent;
                          await _prefs.setString(
                            _profilesKey,
                            jsonEncode(_savedProfiles),
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '配置 "${importNameController.text}" 已导入。(Profile "${importNameController.text}" imported.)',
                                ),
                              ),
                            );
                          }
                          setDialogState(() {});
                        }
                      } catch (e) {
                        if (mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('导入失败 (Import failed): $e')),
                          );
                      }
                    }
                  },
                ),
                TextButton(
                  child: Text(_tr('closeButton')),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showErrorLogsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: Text(_tr('errorLogsTitle')),
              content: SizedBox(
                width: double.maxFinite,
                child:
                    _errorLogs.isEmpty
                        ? Center(child: Text(_tr('noLogs')))
                        : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _errorLogs.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 4.0,
                              ),
                              child: Text(
                                _errorLogs[index],
                                style: const TextStyle(fontSize: 12),
                              ),
                            );
                          },
                        ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _clearErrorLogs();
                    setDialogState(() {});
                  },
                  child: Text(_tr('clearLogsButton')),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_tr('closeButton')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget mainContent = Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: _currentReadingTheme.backgroundColor,
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                ),
                borderRadius: BorderRadius.circular(12.0),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child:
                  _processedTextChunks.isEmpty && !_isLoading
                      ? Center(
                        child: Text(
                          _mainTextHolderController.text.isEmpty
                              ? '请通过右下角按钮输入或加载文本。\n(Please input or load text via the bottom-right button.)'
                              : '待朗读的文本将显示在此处。\n(Text to be read will appear here.)',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _currentReadingTheme.textColor.withOpacity(
                              0.7,
                            ),
                            fontSize: 16,
                          ),
                        ),
                      )
                      : ListView.builder(
                        controller: _displayAreaScrollController,
                        itemCount: _processedTextChunks.length,
                        itemBuilder: (context, index) {
                          final chunkData = _processedTextChunks[index];
                          final chunkText = chunkData['text'] as String;
                          final chunkStartIndex =
                              chunkData['startIndex'] as int;
                          final bool isThisChunkCurrentlyPlaying =
                              index == _currentlyPlayingChunkIndex;
                          final bool isBookmarked = _bookmarks.contains(
                            chunkStartIndex,
                          );

                          if (index >= _chunkKeys.length) {
                            return Text(
                              chunkText,
                              style: TextStyle(
                                color: _currentReadingTheme.textColor,
                              ),
                            ); // Fallback
                          }

                          List<TextSpan> spans = [];
                          if (isThisChunkCurrentlyPlaying) {
                            for (int i = 0; i < chunkText.length; i++) {
                              spans.add(
                                TextSpan(
                                  text: chunkText[i],
                                  style: TextStyle(
                                    fontSize: 17,
                                    color:
                                        i <= _highlightedCharacterInChunkIndex
                                            ? _currentReadingTheme
                                                .karaokeTextColor
                                            : _currentReadingTheme
                                                .playingChunkTextColor,
                                    fontWeight: FontWeight.bold,
                                    backgroundColor:
                                        i <= _highlightedCharacterInChunkIndex
                                            ? _currentReadingTheme
                                                .karaokeFillColor
                                            : Colors.transparent,
                                  ),
                                ),
                              );
                            }
                          } else {
                            spans.add(
                              TextSpan(
                                text: chunkText,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: _currentReadingTheme.textColor,
                                ),
                              ),
                            );
                          }

                          return GestureDetector(
                            onTap: () => _handleChunkTap(index),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 6.0,
                              ),
                              child: Row(
                                key: _chunkKeys[index],
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: RichText(
                                      text: TextSpan(
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: _currentReadingTheme.textColor,
                                        ),
                                        children: spans,
                                      ),
                                    ),
                                  ),
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap:
                                          () =>
                                              _toggleBookmark(chunkStartIndex),
                                      borderRadius: BorderRadius.circular(24),
                                      child: Padding(
                                        padding: const EdgeInsets.all(8.0),
                                        child: Icon(
                                          isBookmarked
                                              ? Icons.star
                                              : Icons.star_border,
                                          color:
                                              isBookmarked
                                                  ? Colors.amber[600]
                                                  : Colors.grey,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ),
          const SizedBox(height: 12),
          _buildBottomStatusArea(theme),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: _currentReadingTheme.backgroundColor,
      body: SafeArea(
        child:
            _currentReadingTheme.applyBlur
                ? BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                  child: Container(
                    color: Colors.transparent,
                    child: mainContent,
                  ),
                )
                : mainContent,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _buildFloatingActionButtons(theme),
    );
  }

  Widget _buildBottomStatusArea(ThemeData theme) {
    bool isPlayerActive =
        (Platform.isWindows &&
            _windowsAudioPlayer.state != ap.PlayerState.stopped) ||
        (!Platform.isWindows &&
            _justAudioPlayer.playing &&
            _justAudioPlayer.processingState != ja.ProcessingState.idle);
    bool showProgress =
        _processedTextChunks.isNotEmpty &&
        (isPlayerActive || _isLoading) &&
        _currentlyPlayingChunkIndex >= 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showProgress)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value:
                            (_currentlyPlayingChunkIndex + 1) /
                            _processedTextChunks.length,
                        backgroundColor: _currentReadingTheme.textColor
                            .withOpacity(0.2),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _currentReadingTheme.playingChunkTextColor,
                        ),
                        minHeight: 6,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${_tr('chunkLabel')}: ${_currentlyPlayingChunkIndex + 1}/${_processedTextChunks.length} (${((_currentlyPlayingChunkIndex + 1) / _processedTextChunks.length * 100).toStringAsFixed(0)}%)',
                            style: TextStyle(
                              fontSize: 10,
                              color: _currentReadingTheme.textColor.withOpacity(
                                0.7,
                              ),
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${_tr('speedLabel')}: ${_playbackSpeed.toStringAsFixed(2)}x',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: _currentReadingTheme.textColor
                                      .withOpacity(0.7),
                                ),
                              ),
                              if (_isBufferingInBackground && !_isLoading)
                                Text(
                                  _backgroundBufferingPreviewText != null
                                      ? '${_tr('bufferingLabel')}:“${_truncateText(_backgroundBufferingPreviewText!, 10)}”'
                                      : '${_tr('bufferingLabel')}...',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _currentReadingTheme.textColor
                                        .withOpacity(0.7),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_isLoading &&
            (_currentlyFetchingChunkText != null || !_isBufferingInBackground))
          Padding(
            padding: const EdgeInsets.only(top: 4.0, bottom: 0),
            child: Center(
              child: Text(
                _currentlyFetchingChunkText != null &&
                        _currentlyFetchingChunkText!.isNotEmpty
                    ? '${_tr('loadingLabel')}：“${_truncateText(_currentlyFetchingChunkText!, 25)}”...'
                    : '${_tr('loadingLabel')}...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: _currentReadingTheme.textColor.withOpacity(0.8),
                ),
              ),
            ),
          )
        else if (_isLoading)
          Padding(
            padding: const EdgeInsets.only(top: 4.0, bottom: 0),
            child: Center(
              child: Text(
                '${_tr('loadingLabel')}...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: _currentReadingTheme.textColor.withOpacity(0.8),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFloatingActionButtons(ThemeData theme) {
    // Since animations are removed, we directly build the buttons.
    List<Widget> leftFabs = [];
    List<Widget> rightFabs = [];

    // Player Controls (Left)
    if (Platform.isWindows) {
      final windowsPlayerState =
          _windowsAudioPlayer.state; // Get current state directly
      final isWindowsPlaying = windowsPlayerState == ap.PlayerState.playing;

      if (_isLoading &&
          _currentlyFetchingChunkText == null &&
          !_isBufferingInBackground) {
        leftFabs.add(
          FloatingActionButton.small(
            onPressed: _stopPlayback,
            tooltip: _tr('cancelLoadingButton'),
            heroTag: 'cancelLoadFabLeftWin',
            backgroundColor: Colors.grey[400],
            child: const Icon(Icons.cancel_outlined),
          ),
        );
      } else if (isWindowsPlaying) {
        leftFabs.addAll([
          FloatingActionButton.small(
            onPressed: () => _windowsAudioPlayer.pause(),
            tooltip: _tr('pauseButton'),
            heroTag: 'pauseFabLeftWin',
            child: const Icon(Icons.pause_circle_filled_outlined),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            onPressed: _stopPlayback,
            tooltip: _tr('stopButton'),
            heroTag: 'stopFabLeftWin',
            backgroundColor: Colors.red.shade300,
            child: const Icon(Icons.stop_circle_outlined, color: Colors.white),
          ),
        ]);
      } else if (windowsPlayerState == ap.PlayerState.paused &&
          _processedTextChunks.isNotEmpty) {
        leftFabs.addAll([
          FloatingActionButton.small(
            onPressed: () => _windowsAudioPlayer.resume(),
            tooltip: _tr('resumeButton'),
            heroTag: 'resumeFabLeftWin',
            backgroundColor: Colors.green.shade300,
            child: const Icon(
              Icons.play_circle_filled_outlined,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            onPressed: _stopPlayback,
            tooltip: _tr('stopButton'),
            heroTag: 'stopFabLeftPausedWin',
            backgroundColor: Colors.red.shade300,
            child: const Icon(Icons.stop_circle_outlined, color: Colors.white),
          ),
        ]);
      } else {
        leftFabs.add(
          FloatingActionButton(
            onPressed:
                (_mainTextHolderController.text.isNotEmpty && !_isLoading)
                    ? _speakText
                    : null,
            tooltip: _tr('readAloudButton'),
            heroTag: 'readAloudFabLeftWin',
            backgroundColor: theme.colorScheme.primary,
            child: Icon(
              Icons.volume_up_outlined,
              color: theme.colorScheme.onPrimary,
            ),
          ),
        );
      }
    } else {
      // Non-Windows (just_audio)
      final isJustAudioPlaying = _justAudioPlayer.playing;
      final justAudioProcessingState = _justAudioPlayer.processingState;

      if (_isLoading &&
          _currentlyFetchingChunkText == null &&
          !_isBufferingInBackground) {
        leftFabs.add(
          FloatingActionButton.small(
            onPressed: _stopPlayback,
            tooltip: _tr('cancelLoadingButton'),
            heroTag: 'cancelLoadFabLeft',
            backgroundColor: Colors.grey[400],
            child: const Icon(Icons.cancel_outlined),
          ),
        );
      } else if (isJustAudioPlaying) {
        leftFabs.addAll([
          FloatingActionButton.small(
            onPressed: () => _justAudioPlayer.pause(),
            tooltip: _tr('pauseButton'),
            heroTag: 'pauseFabLeft',
            child: const Icon(Icons.pause_circle_filled_outlined),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            onPressed: _stopPlayback,
            tooltip: _tr('stopButton'),
            heroTag: 'stopFabLeft',
            backgroundColor: Colors.red.shade300,
            child: const Icon(Icons.stop_circle_outlined, color: Colors.white),
          ),
        ]);
      } else if (!isJustAudioPlaying &&
          (justAudioProcessingState == ja.ProcessingState.buffering ||
              justAudioProcessingState == ja.ProcessingState.ready) &&
          _playlist != null &&
          _playlist!.length > 0 &&
          _justAudioPlayer.audioSource != null) {
        leftFabs.addAll([
          FloatingActionButton.small(
            onPressed: () => _justAudioPlayer.play(),
            tooltip: _tr('resumeButton'),
            heroTag: 'resumeFabLeft',
            backgroundColor: Colors.green.shade300,
            child: const Icon(
              Icons.play_circle_filled_outlined,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            onPressed: _stopPlayback,
            tooltip: _tr('stopButton'),
            heroTag: 'stopFabLeftPaused',
            backgroundColor: Colors.red.shade300,
            child: const Icon(Icons.stop_circle_outlined, color: Colors.white),
          ),
        ]);
      } else {
        leftFabs.add(
          FloatingActionButton(
            onPressed:
                (_mainTextHolderController.text.isNotEmpty && !_isLoading)
                    ? _speakText
                    : null,
            tooltip: _tr('readAloudButton'),
            heroTag: 'readAloudFabLeft',
            backgroundColor: theme.colorScheme.primary,
            child: Icon(
              Icons.volume_up_outlined,
              color: theme.colorScheme.onPrimary,
            ),
          ),
        );
      }
    }

    // Utility Buttons (Right)
    rightFabs.addAll([
      FloatingActionButton(
        onPressed: _showTextInputDialog,
        tooltip: _tr('inputTextButton'),
        heroTag: 'inputTextFabRight',
        mini: true,
        child: const Icon(Icons.edit_note_outlined),
      ),
      const SizedBox(height: 10),
      FloatingActionButton(
        onPressed: _showBookmarksDialog,
        tooltip: _tr('bookmarksButton'),
        heroTag: 'bookmarksFabRight',
        mini: true,
        child: const Icon(Icons.bookmark_outline),
      ),
      const SizedBox(height: 10),
      FloatingActionButton(
        onPressed: _showPlaybackSpeedDialog,
        tooltip: _tr('playbackSpeedButton'),
        heroTag: 'speedFabRight',
        mini: true,
        child: const Icon(Icons.speed_outlined),
      ),
      const SizedBox(height: 10),
      FloatingActionButton(
        onPressed: _showVolumeDialog,
        tooltip: _tr('volumeButton'),
        heroTag: 'volumeFabRight',
        mini: true,
        child: const Icon(Icons.volume_down_outlined),
      ), // New Volume Button
      const SizedBox(height: 10),
      FloatingActionButton(
        onPressed: _showSettingsDialog,
        tooltip: _tr('settingsButton'),
        heroTag: 'settingsFabRight',
        mini: true,
        child: const Icon(Icons.settings_outlined),
      ),
    ]);

    return Stack(
      children: [
        Positioned(
          left: 32.0,
          bottom: 48.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: leftFabs,
          ),
        ),
        Positioned(
          right: 0.0,
          bottom: 48.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: rightFabs,
          ),
        ),
      ],
    );
  }
}
