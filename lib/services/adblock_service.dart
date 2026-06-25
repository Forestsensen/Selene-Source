import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 内置 M3U8 广告拦截服务
///
/// 通过本地 HTTP 代理服务器拦截 M3U8 请求，
/// 解析播放列表并移除广告片段，返回干净的播放列表。
/// 替代外部 U3M8 代理方案。
class AdBlockService {
  static AdBlockService? _instance;
  static AdBlockService get instance => _instance ??= AdBlockService._();

  AdBlockService._();

  HttpServer? _proxyServer;
  int _proxyPort = 0;
  final Dio _dio = Dio();

  // 已知的广告域名模式
  static final List<RegExp> _adDomainPatterns = [
    RegExp(r'ads?\.', caseSensitive: false),
    RegExp(r'adserver', caseSensitive: false),
    RegExp(r'adbreak', caseSensitive: false),
    RegExp(r'doubleclick\.net', caseSensitive: false),
    RegExp(r'googlesyndication', caseSensitive: false),
    RegExp(r'googleadservices', caseSensitive: false),
    RegExp(r'adsterra', caseSensitive: false),
    RegExp(r'propellerads', caseSensitive: false),
    RegExp(r'popads', caseSensitive: false),
    RegExp(r'revive-adserver', caseSensitive: false),
    RegExp(r'advert', caseSensitive: false),
    RegExp(r'banner\.', caseSensitive: false),
    RegExp(r'sponsor', caseSensitive: false),
    RegExp(r'mediaad\.org', caseSensitive: false),
    RegExp(r'adblock', caseSensitive: false),
  ];

  // 广告相关 URL 路径模式
  static final List<RegExp> _adPathPatterns = [
    RegExp(r'/ad[s]?/', caseSensitive: false),
    RegExp(r'/advert', caseSensitive: false),
    RegExp(r'/commercial/', caseSensitive: false),
    RegExp(r'/sponsor/', caseSensitive: false),
    RegExp(r'/banner/', caseSensitive: false),
    RegExp(r'/preroll/', caseSensitive: false),
    RegExp(r'/midroll/', caseSensitive: false),
    RegExp(r'/postroll/', caseSensitive: false),
    RegExp(r'/ad-?segment', caseSensitive: false),
    RegExp(r'/ad_?break', caseSensitive: false),
  ];

  /// 获取本地代理服务器地址
  String get proxyUrl {
    if (_proxyPort == 0) return '';
    return 'http://127.0.0.1:$_proxyPort';
  }

  /// 启动本地代理服务器
  Future<void> startProxy() async {
    if (_proxyServer != null) return;

    try {
      _proxyServer = await HttpServer.bind('127.0.0.1', 0);
      _proxyPort = _proxyServer!.port;

      debugPrint('[AdBlock] 本地代理服务器启动: http://127.0.0.1:$_proxyPort');

      _proxyServer!.listen((HttpRequest request) async {
        await _handleRequest(request);
      });
    } catch (e) {
      debugPrint('[AdBlock] 启动代理服务器失败: $e');
      _proxyServer = null;
      _proxyPort = 0;
    }
  }

  /// 停止本地代理服务器
  Future<void> stopProxy() async {
    if (_proxyServer != null) {
      await _proxyServer!.close(force: true);
      _proxyServer = null;
      _proxyPort = 0;
      debugPrint('[AdBlock] 本地代理服务器已停止');
    }
  }

  /// 处理代理请求
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final uri = request.uri;
      final targetUrl = uri.queryParameters['url'];

      if (targetUrl == null || targetUrl.isEmpty) {
        request.response
          ..statusCode = 400
          ..write('Missing url parameter')
          ..close();
        return;
      }

      debugPrint('[AdBlock] 代理请求: $targetUrl');

      // 获取原始内容
      final response = await _dio.get(
        targetUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': '*/*',
            'Referer': _extractBaseUrl(targetUrl),
          },
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final content = response.data as String;

      // 判断是否为 M3U8 内容
      if (_isM3U8Content(content)) {
        final cleanedContent = _filterM3U8Content(content, targetUrl);
        debugPrint('[AdBlock] M3U8 内容已过滤');

        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.parse('application/vnd.apple.mpegurl')
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..headers.set('Cache-Control', 'no-cache')
          ..write(cleanedContent)
          ..close();
      } else {
        // 非 M3U8 内容，直接透传
        request.response
          ..statusCode = 200
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..write(content)
          ..close();
      }
    } catch (e) {
      debugPrint('[AdBlock] 代理请求失败: $e');
      try {
        request.response
          ..statusCode = 502
          ..write('Proxy error: $e')
          ..close();
      } catch (_) {}
    }
  }

  /// 判断内容是否为 M3U8 格式
  bool _isM3U8Content(String content) {
    final trimmed = content.trim();
    return trimmed.startsWith('#EXTM3U') ||
        trimmed.contains('#EXT-X-VERSION') ||
        trimmed.contains('#EXT-X-TARGETDURATION') ||
        trimmed.contains('#EXT-X-STREAM-INF');
  }

  /// 过滤 M3U8 内容中的广告片段
  String _filterM3U8Content(String content, String baseUrl) {
    final lines = content.split('\n');
    final result = <String>[];
    bool inAdBlock = false;
    int removedSegments = 0;

    // 先检查是否为主播放列表（master playlist）
    bool isMasterPlaylist = false;
    for (final line in lines) {
      if (line.trim().startsWith('#EXT-X-STREAM-INF:')) {
        isMasterPlaylist = true;
        break;
      }
    }

    // 如果是主播放列表，通过本地代理重写子播放列表 URL
    if (isMasterPlaylist) {
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          result.add(line);
        } else {
          // 这是子播放列表的 URL，通过代理重写
          final absoluteUrl = _resolveUrl(trimmed, baseUrl);
          result.add('$proxyUrl/proxy?url=${Uri.encodeComponent(absoluteUrl)}');
        }
      }
      return result.join('\n');
    }

    // 媒体播放列表（media playlist）- 过滤广告片段
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // 检测广告起始标记
      if (_isAdStartMarker(trimmed)) {
        inAdBlock = true;
        removedSegments++;
        continue;
      }

      // 检测广告结束标记
      if (_isAdEndMarker(trimmed)) {
        inAdBlock = false;
        continue;
      }

      // 在广告块内，跳过所有内容
      if (inAdBlock) {
        continue;
      }

      // 检测独立的广告片段（基于 URL 模式）
      if (_isAdSegment(trimmed, lines, i)) {
        // 跳过当前行和前一行（通常是 #EXTINF）
        if (result.isNotEmpty &&
            result.last.trim().startsWith('#EXTINF')) {
          result.removeLast();
        }
        removedSegments++;
        continue;
      }

      result.add(line);
    }

    if (removedSegments > 0) {
      debugPrint('[AdBlock] 已移除 $removedSegments 个广告片段');
    }

    return result.join('\n');
  }

  /// 检测广告起始标记
  bool _isAdStartMarker(String line) {
    // SCTE-35 广告插入标记
    if (line.startsWith('#EXT-X-CUE-OUT')) return true;
    if (line.startsWith('#EXT-X-SCTE35')) return true;
    if (line.startsWith('#EXT-X-SCTE-OUT')) return true;

    // 广告 DATERANGE 标记
    if (line.startsWith('#EXT-X-DATERANGE') &&
        (line.contains('CLASS="ad"') ||
            line.contains('CLASS="commercial"') ||
            line.contains('SCTE35-OUT'))) {
      return true;
    }

    return false;
  }

  /// 检测广告结束标记
  bool _isAdEndMarker(String line) {
    if (line.startsWith('#EXT-X-CUE-IN')) return true;
    if (line.startsWith('#EXT-X-SCTE-IN')) return true;

    // DATERANGE 广告结束
    if (line.startsWith('#EXT-X-DATERANGE') &&
        line.contains('SCTE35-IN')) {
      return true;
    }

    return false;
  }

  /// 检测单个广告片段
  bool _isAdSegment(String line, List<String> allLines, int currentIndex) {
    // 跳过空行和注释
    if (line.isEmpty || line.startsWith('#')) return false;

    // 检查 URL 是否匹配广告域名模式
    for (final pattern in _adDomainPatterns) {
      if (pattern.hasMatch(line)) {
        debugPrint('[AdBlock] 匹配广告域名: $line');
        return true;
      }
    }

    // 检查 URL 是否匹配广告路径模式
    for (final pattern in _adPathPatterns) {
      if (pattern.hasMatch(line)) {
        debugPrint('[AdBlock] 匹配广告路径: $line');
        return true;
      }
    }

    // 检查 URL 是否包含明显的广告关键词
    final lowerLine = line.toLowerCase();
    if (lowerLine.contains('/ad/') ||
        lowerLine.contains('/ads/') ||
        lowerLine.contains('/advert') ||
        lowerLine.contains('adsegment') ||
        lowerLine.contains('ad_break') ||
        lowerLine.contains('preroll') ||
        lowerLine.contains('midroll') ||
        lowerLine.contains('postroll')) {
      debugPrint('[AdBlock] 匹配广告关键词: $line');
      return true;
    }

    // 检查前一行的 EXTINF 时长 - 极短的片段通常是广告
    if (currentIndex > 0) {
      final prevLine = allLines[currentIndex - 1].trim();
      if (prevLine.startsWith('#EXTINF:')) {
        final durationStr =
            prevLine.substring('#EXTINF:'.length).split(',').first.trim();
        final duration = double.tryParse(durationStr);
        if (duration != null && duration > 0 && duration <= 5.0) {
          // 5秒以下的片段很可能是广告，但要结合上下文判断
          // 检查是否在非广告区域（如果是第一个或最后一个片段，不一定是广告）
          if (currentIndex > 2 && currentIndex < allLines.length - 2) {
            // 检查前后是否有 discontinuity（广告标志）
            bool hasDiscontinuity = false;
            for (int j = currentIndex - 3; j >= 0 && j >= currentIndex - 5; j--) {
              if (allLines[j].trim().startsWith('#EXT-X-DISCONTINUITY')) {
                hasDiscontinuity = true;
                break;
              }
            }
            if (hasDiscontinuity) {
              debugPrint('[AdBlock] 匹配短时长+discontinuity: ${duration}s');
              return true;
            }
          }
        }
      }
    }

    return false;
  }

  /// 解析相对 URL 为绝对 URL
  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    final baseUri = Uri.parse(baseUrl);
    if (url.startsWith('/')) {
      return '${baseUri.scheme}://${baseUri.host}'
          '${baseUri.hasPort ? ':${baseUri.port}' : ''}$url';
    } else {
      final basePath =
          baseUri.path.substring(0, baseUri.path.lastIndexOf('/') + 1);
      return '${baseUri.scheme}://${baseUri.host}'
          '${baseUri.hasPort ? ':${baseUri.port}' : ''}$basePath$url';
    }
  }

  /// 提取 baseUrl（scheme + host + port）
  String _extractBaseUrl(String url) {
    final uri = Uri.parse(url);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }

  /// 释放资源
  void dispose() {
    stopProxy();
    _dio.close();
  }
}
