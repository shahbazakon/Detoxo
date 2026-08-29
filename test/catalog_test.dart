import 'dart:convert';

import 'package:detoxo/core/utils/package_name.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/config_repository_impl.dart';
import 'package:detoxo/features/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the shipped taxonomy the way `bundled_config_test.dart` guards the
/// platforms config: the seed is static data, so a bad edit must fail here,
/// not silently reclassify an app on devices.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = Catalog.bundled;

  group('seed integrity', () {
    test('category ids are unique and every category has a service', () {
      final ids = AppCategorySeed.categories.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final c in AppCategorySeed.categories) {
        expect(c.services, isNotEmpty, reason: c.id);
      }
    });

    test('no package is claimed by two categories', () {
      final owner = <String, String>{};
      for (final c in AppCategorySeed.categories) {
        for (final s in c.services) {
          for (final pkg in s.androidPackages) {
            expect(
              owner[pkg],
              anyOf(isNull, c.id),
              reason: '$pkg is in both ${owner[pkg]} and ${c.id}',
            );
            owner[pkg] = c.id;
            expect(isValidPackageName(pkg), isTrue, reason: pkg);
          }
        }
      }
    });

    test('the 18 legacy app→domain pairs are preserved exactly', () {
      // The map `AppDomainCatalog` shipped before the catalog replaced it —
      // "block sites for blocked apps" must keep deriving the same domains.
      const legacy = <String, Set<String>>{
        'com.google.android.youtube': {'youtube.com', 'youtu.be'},
        'com.google.android.apps.youtube.music': {'music.youtube.com'},
        'com.netflix.mediaclient': {'netflix.com'},
        'com.amazon.avod.thirdpartyclient': {'primevideo.com'},
        'com.disney.disneyplus': {'disneyplus.com'},
        'tv.twitch.android.app': {'twitch.tv'},
        'com.instagram.android': {'instagram.com'},
        'com.facebook.katana': {'facebook.com', 'fb.com'},
        'com.facebook.lite': {'facebook.com', 'fb.com'},
        'com.twitter.android': {'x.com', 'twitter.com'},
        'com.reddit.frontpage': {'reddit.com'},
        'com.snapchat.android': {'snapchat.com'},
        'com.pinterest': {'pinterest.com'},
        'com.linkedin.android': {'linkedin.com'},
        'com.quora.android': {'quora.com'},
        'com.tumblr': {'tumblr.com'},
        'com.zhiliaoapp.musically': {'tiktok.com'},
        'com.ss.android.ugc.trill': {'tiktok.com'},
      };
      expect(legacy.length, 18);
      legacy.forEach((pkg, domains) {
        expect(catalog.domainsForPackage(pkg).toSet(), domains, reason: pkg);
      });
      expect(catalog.domainsForPackage('com.unknown.app'), isEmpty);
    });

    test(
      'every real package in the shipped platforms config is categorised',
      () async {
        final raw = await ConfigRepositoryImpl().rawConfigJson();
        final apps =
            (jsonDecode(raw) as Map<String, dynamic>)['featuredApps']
                as Map<String, dynamic>;
        final packages = [
          for (final app in apps.values)
            (app as Map<String, dynamic>)['packageName'] as String,
        ];
        final real = packages.where(isValidPackageName).toList();
        // One entry is a detection pseudo-target, not an installable app.
        expect(packages.length - real.length, 1);
        for (final pkg in real) {
          expect(catalog.categoryForPackage(pkg), isNotNull, reason: pkg);
        }
      },
    );

    test('the reel-hosting social apps are distracting', () {
      for (final pkg in const [
        'com.instagram.android',
        'com.zhiliaoapp.musically',
        'com.ss.android.ugc.trill',
        'com.google.android.youtube',
        'com.facebook.katana',
        'com.snapchat.android',
        'com.twitter.android',
      ]) {
        expect(
          catalog.behaviorForPackage(pkg),
          AppBehavior.distracting,
          reason: pkg,
        );
      }
      // Surfaces are detected inside these, but the apps themselves are not.
      expect(catalog.behaviorForPackage('com.whatsapp'), AppBehavior.neutral);
      expect(
        catalog.behaviorForPackage('xyz.penpencil.physicswala'),
        AppBehavior.productive,
      );
    });

    test('packagesIn lists a category in seed order', () {
      expect(
        catalog.packagesIn('short_form_video'),
        containsAllInOrder([
          'com.instagram.android',
          'com.zhiliaoapp.musically',
        ]),
      );
      expect(catalog.packagesIn('nope'), isEmpty);
    });
  });

  group('host resolution', () {
    test('subdomains, www and the trailing-dot form all resolve', () {
      expect(catalog.categoryForHost('m.facebook.com')?.id, 'social');
      expect(catalog.categoryForHost('www.facebook.com')?.id, 'social');
      expect(catalog.categoryForHost('facebook.com.')?.id, 'social');
      expect(
        catalog.categoryForHost('  Instagram.COM ')?.id,
        'short_form_video',
      );
      expect(catalog.serviceForHost('music.youtube.com')?.id, 'youtube_music');
      expect(catalog.serviceForHost('m.youtube.com')?.id, 'youtube');
    });

    test('a bare TLD or an unknown host resolves to null', () {
      expect(catalog.categoryForHost('com'), isNull);
      expect(catalog.categoryForHost('example.com'), isNull);
      expect(catalog.categoryForHost(''), isNull);
    });

    test('suffixesOf stops before the TLD', () {
      expect(Catalog.suffixesOf('m.facebook.com').toList(), [
        'm.facebook.com',
        'facebook.com',
      ]);
      expect(Catalog.suffixesOf('com').toList(), isEmpty);
    });

    test('normalizeHost', () {
      expect(Catalog.normalizeHost(' WWW.Glu.com. '), 'glu.com');
      expect(Catalog.normalizeHost('youtu.be'), 'youtu.be');
    });
  });

  group('AppBehavior', () {
    test('unknown wire falls back to neutral', () {
      expect(AppBehavior.fromWire('weird'), AppBehavior.neutral);
      expect(AppBehavior.fromWire(null), AppBehavior.neutral);
      expect(AppBehavior.fromWire('distracting'), AppBehavior.distracting);
    });

    test('an unknown package is neutral', () {
      expect(catalog.behaviorForPackage('com.unknown'), AppBehavior.neutral);
    });
  });

  group('Catalog.empty', () {
    test('every lookup is null / neutral / empty', () {
      const empty = Catalog.empty;
      expect(empty.categories, isEmpty);
      expect(empty.categoryForPackage('com.instagram.android'), isNull);
      expect(empty.categoryForHost('instagram.com'), isNull);
      expect(
        empty.behaviorForPackage('com.instagram.android'),
        AppBehavior.neutral,
      );
      expect(empty.domainsForPackage('com.instagram.android'), isEmpty);
      expect(empty.packagesIn('social'), isEmpty);
    });

    test('a collision keeps the last writer', () {
      final c = Catalog.build(const [
        AppCategory(
          id: 'a',
          displayName: 'A',
          behavior: AppBehavior.productive,
          services: [
            CategoryService(
              id: 's1',
              displayName: 'S1',
              androidPackages: ['x.y'],
            ),
          ],
        ),
        AppCategory(
          id: 'b',
          displayName: 'B',
          behavior: AppBehavior.distracting,
          services: [
            CategoryService(
              id: 's2',
              displayName: 'S2',
              androidPackages: ['x.y'],
            ),
          ],
        ),
      ]);
      expect(c.categoryForPackage('x.y')?.id, 'b');
    });
  });
}
