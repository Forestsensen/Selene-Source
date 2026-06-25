import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 内置 M3U8 广告过滤服务
///
/// 在 App 内部预取 M3U8 内容，过滤广告片段，保存为本地临时文件。
/// media_kit 播放本地文件，分片仍从源站直连。
class AdBlockService {
  static final AdBlockService _instance = AdBlockService._();
  static AdBlockService get instance => _instance;

  AdBlockService._();

  final Dio _dio = Dio();

  // 爱奇艺/猫眼等特定平台广告特征
  static const List<String> _adKeywords = [
    'cupid.iqiyi.com',
    'afp.iqiyi.com',
    'ad.m.iqiyi.com',
    'policy.video.iqiyi.com',
    't7.cupid.iqiyi.com',
    'ad.maoyan.com',
    'analytics.maoyan.com',
    'maoyan.com/advert',
    'maoyan.com/tracking',
    'analytics.meituan',
    'stat.mafengwo',
    'meituan.com/advert',
    'meituan.com/tracking',
    's3plus.meituan.com',
    'report.meituan.com',
    'pre_roll',
    'mid_roll',
    'post_roll',
    'preroll',
    'midroll',
    'postroll',
    'doubleclick.net',
    'googlesyndication.com',
    'adservice.google.com',
  ];

  /// 预取 M3U8 内容，过滤广告，返回本地文件路径
  /// 如果过滤失败或无需过滤，返回原始 URL
  Future<String> filterM3U8(String m3u8Url) async {
    try {
      // 获取 M3U8 内容
      final response = await _dio.get(
        m3u8Url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      final content = response.data as String;

      // 检查是否为 M3U8 内容
      if (!content.trim().startsWith('#EXTM3U')) {
        debugPrint('[AdBlock] 非 M3U8 内容，跳过过滤');
        return m3u8Url;
      }

      // 检查是否为 master playlist（包含多个质量变体）
      if (content.contains('#EXT-X-STREAM-INF:')) {
        // master playlist 不需要过滤广告，直接返回
        // 广告过滤在 media playlist 层级进行
        debugPrint('[AdBlock] Master playlist，跳过过滤');
        return m3u8Url;
      }

      // 过滤广告片段
      final filteredContent = _filterAds(content);

      if (filteredContent == content) {
        // 没有广告被过滤，返回原始 URL
        debugPrint('[AdBlock] 无广告片段，使用原始 URL');
        return m3u8Url;
      }

      // 保存到临时文件
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/selene_adblock_${DateTime.now().millisecondsSinceEpoch}.m3u8');
      await tempFile.writeAsString(filteredContent);

      debugPrint('[AdBlock] 已过滤广告，保存到: ${tempFile.path}');
      return tempFile.path;
    } catch (e) {
      debugPrint('[AdBlock] 过滤失败，使用原始 URL: $e');
      return m3u8Url;
    }
  }

  /// 过滤 M3U8 中的广告片段
  String _filterAds(String content) {
    final lines = content.split('\n');
    final result = <String>[];

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];

      // 跳过 #EXT-X-DISCONTINUITY 标识
      if (line.contains('#EXT-X-DISCONTINUITY')) {
        i++;
        continue;
      }

      // 如果是 EXTINF 行，检查下一行 URL 是否包含广告关键字
      if (line.contains('#EXTINF:')) {
        if (i + 1 < lines.length) {
          final nextLine = lines[i + 1].toLowerCase();
          final containsAd = _adKeywords.any(
            (keyword) => nextLine.contains(keyword.toLowerCase()),
          );

          if (containsAd) {
            debugPrint('[AdBlock] 过滤广告片段: ${lines[i + 1]}');
            i += 2; // 跳过 EXTINF 和 URL 行
            continue;
          }
        }
      }

      result.add(line);
      i++;
    }

    return result.join('\n');
  }

  /// 清理过期的临时文件
  Future<void> cleanupTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir.listSync();
      final now = DateTime.now();

      for (final file in files) {
        if (file is File && file.path.contains('selene_adblock_')) {
          final stat = await file.stat();
          final age = now.difference(stat.modified);
          if (age.inMinutes > 30) {
            await file.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('[AdBlock] 清理临时文件失败: $e');
    }
  }

  void dispose() {
    _dio.close();
  }
}
