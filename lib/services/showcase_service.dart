import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';
import '../widgets/card_swap_widget.dart';
import 'app_cache_service.dart';

class ShowcaseService {
  ShowcaseService._internal();
  static final ShowcaseService instance = ShowcaseService._internal();

  static const _cacheKey = 'showcase:slides:v2';
  static const _versionKey = 'showcase:slides:version:v2';
  static const _memoryTtl = Duration(hours: 1);

  final AppCacheService _cache = AppCacheService();

  static const List<Map<String, String>> bundledDefaults = [
    {
      'label': 'CCS SUMMIT',
      'asset_path': 'assets/sample summit/image1.jpg',
    },
    {
      'label': 'GENERAL ASSEMBLY',
      'asset_path': 'assets/sample GA/image1.jpg',
    },
    {
      'label': 'CCS EXHIBIT',
      'asset_path': 'assets/sample exhibit/image1.jpg',
    },
    {
      'label': 'COMPANY VISIT',
      'asset_path': 'assets/sample CV/image1.jpg',
    },
  ];

  List<CardSwapItem> bundledItems() {
    return bundledDefaults
        .map(
          (row) => CardSwapItem(
            label: row['label'] ?? 'Event',
            imagePath: row['asset_path'],
          ),
        )
        .toList(growable: false);
  }

  Future<List<CardSwapItem>> getItems({
    bool forceFresh = false,
    void Function(List<CardSwapItem> items)? onUpdated,
  }) async {
    if (!forceFresh) {
      final cached = await _readCachedItems();
      if (cached.isNotEmpty) {
        unawaited(
          _fetchAndCache(silent: true).then((fresh) {
            if (fresh.isEmpty || !_itemsChanged(cached, fresh)) {
              return;
            }
            onUpdated?.call(fresh);
          }),
        );
        return cached;
      }
    }

    try {
      return await _fetchAndCache(forceFresh: forceFresh);
    } catch (_) {
      final cached = await _readCachedItems();
      return cached;
    }
  }

  Future<List<CardSwapItem>> _readCachedItems() async {
    final mem = _cache.readMemory<List<Map<String, dynamic>>>(
      _cacheKey,
      _memoryTtl,
      forceFresh: false,
    );
    if (mem != null && mem.isNotEmpty) {
      final items = _mapsToItems(mem);
      if (items.isNotEmpty) return items;
    }

    final disk = await _cache.loadJsonList(_cacheKey);
    if (disk.isNotEmpty) {
      final items = _mapsToItems(disk);
      if (items.isNotEmpty) {
        _cache.writeMemory(_cacheKey, disk);
        return items;
      }
    }
    return [];
  }

  Future<List<CardSwapItem>> _fetchAndCache({
    bool forceFresh = false,
    bool silent = false,
  }) async {
    final uri = Uri.parse('${Env.mobilePushApiBaseUrl}/api/showcase_slides.php');
    final headers = <String, String>{'Accept': 'application/json'};
    final cachedVersion = await _cache.loadJsonList(_versionKey);
    final version = cachedVersion.isNotEmpty
        ? (cachedVersion.first['version'] ?? '').toString().trim()
        : '';
    if (version.isNotEmpty) {
      headers['If-None-Match'] = version;
    }

    final res = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 8));

    if (res.statusCode == 304) {
      final cached = await _readCachedItems();
      if (cached.isNotEmpty) return cached;
    }

    if (res.statusCode != 200) {
      if (!silent) throw Exception('showcase_http_${res.statusCode}');
      final cached = await _readCachedItems();
      return cached;
    }

    final decoded = jsonDecode(res.body);
    if (decoded is! Map || decoded['ok'] != true) {
      if (!silent) throw Exception('showcase_invalid_payload');
      final cached = await _readCachedItems();
      return cached;
    }

    final rows = List<Map<String, dynamic>>.from(
      (decoded['slides'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row)),
    );

    final normalized = rows
        .map((row) {
          var imageUrl = (row['image_url'] ?? '').toString().trim();
          var assetPath = (row['asset_path'] ?? '').toString().trim();
          final label = (row['label'] ?? '').toString().trim();
          if (imageUrl.startsWith('/assets/')) {
            assetPath = imageUrl.substring(1);
            imageUrl = '';
          } else if (imageUrl.startsWith('assets/')) {
            assetPath = imageUrl;
            imageUrl = '';
          }
          if (imageUrl.isEmpty && assetPath.isEmpty) return null;
          return {
            'label': label.isEmpty ? 'Event' : label,
            if (imageUrl.isNotEmpty) 'image_url': imageUrl,
            if (assetPath.isNotEmpty) 'asset_path': assetPath,
            'updated_at': (row['updated_at'] ?? '').toString(),
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);

    if (decoded['fallback'] == true) {
      return bundledItems();
    }

    final items = _mapsToItems(normalized);
    if (items.isEmpty) {
      return bundledItems();
    }

    final nextVersion = (decoded['version'] ?? '').toString().trim();
    final hasRemoteImages = normalized.any(
      (row) => (row['image_url'] ?? '').toString().trim().isNotEmpty,
    );
    if (hasRemoteImages && normalized.isNotEmpty) {
      await _cache.saveJsonList(_cacheKey, normalized);
      _cache.writeMemory(_cacheKey, normalized);
      if (nextVersion.isNotEmpty) {
        await _cache.saveJsonList(
          _versionKey,
          [
            {'version': nextVersion},
          ],
        );
      }
    } else if (forceFresh) {
      _cache.invalidateMemory(_cacheKey);
    }

    return items;
  }

  List<CardSwapItem> _mapsToItems(List<Map<String, dynamic>> rows) {
    final items = <CardSwapItem>[];
    for (final row in rows) {
      final label = (row['label'] ?? '').toString().trim();
      final imageUrl = (row['image_url'] ?? '').toString().trim();
      final assetPath = (row['asset_path'] ?? '').toString().trim();
      if (imageUrl.isNotEmpty) {
        items.add(
          CardSwapItem(
            label: label.isEmpty ? 'Event' : label,
            imageUrl: imageUrl,
          ),
        );
      } else if (assetPath.isNotEmpty) {
        items.add(
          CardSwapItem(
            label: label.isEmpty ? 'Event' : label,
            imagePath: assetPath,
          ),
        );
      }
    }
    return items;
  }

  bool _itemsChanged(List<CardSwapItem> before, List<CardSwapItem> after) {
    if (before.length != after.length) return true;
    for (var i = 0; i < before.length; i++) {
      final a = before[i];
      final b = after[i];
      if (a.label != b.label) return true;
      if ((a.imageUrl ?? '') != (b.imageUrl ?? '')) return true;
      if ((a.imagePath ?? '') != (b.imagePath ?? '')) return true;
    }
    return false;
  }

  String itemsKey(List<CardSwapItem> items) {
    return items
        .map(
          (item) =>
              '${item.label}|${item.imageUrl ?? ''}|${item.imagePath ?? ''}',
        )
        .join('§');
  }

  Future<void> prefetchImages(
    BuildContext context,
    List<CardSwapItem> items,
  ) async {
    for (final item in items) {
      final url = item.imageUrl?.trim() ?? '';
      if (url.isEmpty) continue;
      try {
        await precacheImage(CachedNetworkImageProvider(url), context);
      } catch (_) {
        // Non-fatal — disk cache will help on next visit.
      }
    }
  }
}
