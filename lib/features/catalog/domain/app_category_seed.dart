import 'package:detoxo/features/catalog/domain/entities/app_behavior.dart';
import 'package:detoxo/features/catalog/domain/entities/app_category.dart';

/// The shipped app / website taxonomy. Ten categories, three behaviours.
///
/// Rules for editing:
///  - A service owns its packages AND its domains; two products with different
///    domain sets are two services (YouTube vs YouTube Music).
///  - A package appears in exactly one category — `catalog_test.dart` fails
///    otherwise, because the index's last-writer-wins would silently move it.
///  - Every real package in `assets/config/platforms_config.json` must be here,
///    classified by what the APP is, not by the reel surface Detoxo detects in
///    it (WhatsApp Status is a surface; WhatsApp is messaging).
///  - Behaviours are the product's honest default, not a verdict: `news` and
///    `messaging` are neutral so the default never blocks a class of app the
///    user did not pick.
abstract final class AppCategorySeed {
  static const List<AppCategory> categories = [
    // ── Distracting ─────────────────────────────────────────────────────────
    AppCategory(
      id: 'short_form_video',
      displayName: 'Short-form video',
      behavior: AppBehavior.distracting,
      services: [
        CategoryService(
          id: 'instagram',
          displayName: 'Instagram',
          androidPackages: [
            'com.instagram.android',
            'com.instagram.lite',
            'com.instapro.android',
            'com.instapro2.android',
          ],
          domains: ['instagram.com'],
        ),
        CategoryService(
          id: 'tiktok',
          displayName: 'TikTok',
          androidPackages: [
            'com.zhiliaoapp.musically',
            'com.ss.android.ugc.trill',
          ],
          domains: ['tiktok.com'],
        ),
        CategoryService(
          id: 'youtube',
          displayName: 'YouTube',
          androidPackages: [
            'com.google.android.youtube',
            'com.biomes.vanced',
            'app.revanced.android.youtube',
            'com.snaptube.premium',
            'com.sgebrelibanos.aderaser',
          ],
          domains: ['youtube.com', 'youtu.be'],
        ),
        CategoryService(
          id: 'youtube_music',
          displayName: 'YouTube Music',
          androidPackages: ['com.google.android.apps.youtube.music'],
          domains: ['music.youtube.com'],
        ),
        CategoryService(
          id: 'snapchat',
          displayName: 'Snapchat',
          androidPackages: ['com.snapchat.android'],
          domains: ['snapchat.com'],
        ),
        CategoryService(
          id: 'vk_clips',
          displayName: 'VK Clips',
          androidPackages: ['com.vk.clips'],
        ),
      ],
    ),
    AppCategory(
      id: 'social',
      displayName: 'Social',
      behavior: AppBehavior.distracting,
      services: [
        CategoryService(
          id: 'facebook',
          displayName: 'Facebook',
          androidPackages: ['com.facebook.katana', 'com.facebook.lite'],
          domains: ['facebook.com', 'fb.com'],
        ),
        CategoryService(
          id: 'x',
          displayName: 'X',
          androidPackages: ['com.twitter.android'],
          domains: ['x.com', 'twitter.com'],
        ),
        CategoryService(
          id: 'threads',
          displayName: 'Threads',
          androidPackages: ['com.instagram.barcelona'],
          domains: ['threads.net', 'threads.com'],
        ),
        CategoryService(
          id: 'reddit',
          displayName: 'Reddit',
          androidPackages: ['com.reddit.frontpage'],
          domains: ['reddit.com'],
        ),
        CategoryService(
          id: 'pinterest',
          displayName: 'Pinterest',
          androidPackages: ['com.pinterest'],
          domains: ['pinterest.com'],
        ),
        CategoryService(
          id: 'linkedin',
          displayName: 'LinkedIn',
          androidPackages: ['com.linkedin.android'],
          domains: ['linkedin.com'],
        ),
        CategoryService(
          id: 'quora',
          displayName: 'Quora',
          androidPackages: ['com.quora.android'],
          domains: ['quora.com'],
        ),
        CategoryService(
          id: 'tumblr',
          displayName: 'Tumblr',
          androidPackages: ['com.tumblr'],
          domains: ['tumblr.com'],
        ),
        CategoryService(
          id: 'vk',
          displayName: 'VK',
          androidPackages: ['com.vkontakte.android'],
          domains: ['vk.com'],
        ),
        CategoryService(
          id: 'bluesky',
          displayName: 'Bluesky',
          androidPackages: ['xyz.blueskyweb.app'],
          domains: ['bsky.app'],
        ),
      ],
    ),
    AppCategory(
      id: 'video_streaming',
      displayName: 'Video streaming',
      behavior: AppBehavior.distracting,
      services: [
        CategoryService(
          id: 'netflix',
          displayName: 'Netflix',
          androidPackages: ['com.netflix.mediaclient'],
          domains: ['netflix.com'],
        ),
        CategoryService(
          id: 'prime_video',
          displayName: 'Prime Video',
          androidPackages: ['com.amazon.avod.thirdpartyclient'],
          domains: ['primevideo.com'],
        ),
        CategoryService(
          id: 'disney_plus',
          displayName: 'Disney+',
          androidPackages: ['com.disney.disneyplus'],
          domains: ['disneyplus.com'],
        ),
        CategoryService(
          id: 'twitch',
          displayName: 'Twitch',
          androidPackages: ['tv.twitch.android.app'],
          domains: ['twitch.tv'],
        ),
        CategoryService(
          id: 'hotstar',
          displayName: 'Hotstar',
          androidPackages: ['in.startv.hotstar'],
          domains: ['hotstar.com'],
        ),
        CategoryService(
          id: 'jiocinema',
          displayName: 'JioCinema',
          androidPackages: ['com.jio.media.ondemand'],
          domains: ['jiocinema.com'],
        ),
      ],
    ),
    AppCategory(
      id: 'games',
      displayName: 'Games',
      behavior: AppBehavior.distracting,
      services: [
        CategoryService(
          id: 'free_fire',
          displayName: 'Free Fire',
          androidPackages: ['com.dts.freefireth', 'com.dts.freefiremax'],
        ),
        CategoryService(
          id: 'bgmi',
          displayName: 'BGMI',
          androidPackages: ['com.pubg.imobile'],
        ),
        CategoryService(
          id: 'pubg_mobile',
          displayName: 'PUBG Mobile',
          androidPackages: ['com.tencent.ig'],
        ),
        CategoryService(
          id: 'roblox',
          displayName: 'Roblox',
          androidPackages: ['com.roblox.client'],
          domains: ['roblox.com'],
        ),
        CategoryService(
          id: 'minecraft',
          displayName: 'Minecraft',
          androidPackages: ['com.mojang.minecraftpe'],
        ),
        CategoryService(
          id: 'clash_of_clans',
          displayName: 'Clash of Clans',
          androidPackages: ['com.supercell.clashofclans'],
        ),
        CategoryService(
          id: 'candy_crush',
          displayName: 'Candy Crush',
          androidPackages: ['com.king.candycrushsaga'],
        ),
        CategoryService(
          id: 'subway_surfers',
          displayName: 'Subway Surfers',
          androidPackages: ['com.kiloo.subwaysurf'],
        ),
        CategoryService(
          id: 'ludo_king',
          displayName: 'Ludo King',
          androidPackages: ['com.ludo.king'],
        ),
      ],
    ),

    // ── Neutral ─────────────────────────────────────────────────────────────
    AppCategory(
      id: 'news',
      displayName: 'News',
      behavior: AppBehavior.neutral,
      services: [
        CategoryService(
          id: 'google_news',
          displayName: 'Google News',
          androidPackages: ['com.google.android.apps.magazines'],
          domains: ['news.google.com'],
        ),
        CategoryService(
          id: 'inshorts',
          displayName: 'Inshorts',
          androidPackages: ['com.nis.app'],
          domains: ['inshorts.com'],
        ),
        CategoryService(
          id: 'dailyhunt',
          displayName: 'Dailyhunt',
          androidPackages: ['com.eterno'],
          domains: ['dailyhunt.in'],
        ),
        CategoryService(
          id: 'bbc_news',
          displayName: 'BBC News',
          androidPackages: ['bbc.mobile.news.ww'],
          domains: ['bbc.com', 'bbc.co.uk'],
        ),
        CategoryService(
          id: 'ndtv',
          displayName: 'NDTV',
          androidPackages: ['com.july.ndtv'],
          domains: ['ndtv.com'],
        ),
      ],
    ),
    AppCategory(
      id: 'messaging',
      displayName: 'Messaging',
      behavior: AppBehavior.neutral,
      services: [
        CategoryService(
          id: 'whatsapp',
          displayName: 'WhatsApp',
          androidPackages: ['com.whatsapp', 'com.whatsapp.w4b'],
          domains: ['web.whatsapp.com'],
        ),
        CategoryService(
          id: 'telegram',
          displayName: 'Telegram',
          androidPackages: ['org.telegram.messenger'],
          domains: ['web.telegram.org'],
        ),
        CategoryService(
          id: 'messenger',
          displayName: 'Messenger',
          androidPackages: ['com.facebook.orca'],
          domains: ['messenger.com'],
        ),
        CategoryService(
          id: 'signal',
          displayName: 'Signal',
          androidPackages: ['org.thoughtcrime.securesms'],
        ),
        CategoryService(
          id: 'discord',
          displayName: 'Discord',
          androidPackages: ['com.discord'],
          domains: ['discord.com'],
        ),
        CategoryService(
          id: 'google_messages',
          displayName: 'Google Messages',
          androidPackages: ['com.google.android.apps.messaging'],
          domains: ['messages.google.com'],
        ),
      ],
    ),
    AppCategory(
      id: 'browsers',
      displayName: 'Browsers',
      behavior: AppBehavior.neutral,
      services: [
        CategoryService(
          id: 'chrome',
          displayName: 'Chrome',
          androidPackages: ['com.android.chrome'],
        ),
        CategoryService(
          id: 'firefox',
          displayName: 'Firefox',
          androidPackages: ['org.mozilla.firefox'],
        ),
        CategoryService(
          id: 'brave',
          displayName: 'Brave',
          androidPackages: ['com.brave.browser'],
        ),
        CategoryService(
          id: 'edge',
          displayName: 'Edge',
          androidPackages: ['com.microsoft.emmx'],
        ),
        CategoryService(
          id: 'samsung_internet',
          displayName: 'Samsung Internet',
          androidPackages: ['com.sec.android.app.sbrowser'],
        ),
        CategoryService(
          id: 'opera',
          displayName: 'Opera',
          androidPackages: ['com.opera.browser', 'com.opera.mini.native'],
        ),
        CategoryService(
          id: 'jio_web',
          displayName: 'JioSphere',
          androidPackages: ['com.jio.web'],
        ),
      ],
    ),
    AppCategory(
      id: 'tools',
      displayName: 'Tools',
      behavior: AppBehavior.neutral,
      services: [
        CategoryService(
          id: 'google_maps',
          displayName: 'Google Maps',
          androidPackages: ['com.google.android.apps.maps'],
          domains: ['maps.google.com'],
        ),
        CategoryService(
          id: 'play_store',
          displayName: 'Play Store',
          androidPackages: ['com.android.vending'],
          domains: ['play.google.com'],
        ),
        CategoryService(
          id: 'settings',
          displayName: 'Settings',
          androidPackages: ['com.android.settings'],
        ),
        CategoryService(
          id: 'files',
          displayName: 'Files',
          androidPackages: [
            'com.google.android.apps.nbu.files',
            'com.google.android.documentsui',
          ],
        ),
        CategoryService(
          id: 'camera',
          displayName: 'Camera',
          androidPackages: ['com.google.android.GoogleCamera'],
        ),
        CategoryService(
          id: 'clock',
          displayName: 'Clock',
          androidPackages: ['com.google.android.deskclock'],
        ),
        CategoryService(
          id: 'calculator',
          displayName: 'Calculator',
          androidPackages: ['com.google.android.calculator'],
        ),
      ],
    ),

    // ── Productive ──────────────────────────────────────────────────────────
    AppCategory(
      id: 'productivity',
      displayName: 'Productivity',
      behavior: AppBehavior.productive,
      services: [
        CategoryService(
          id: 'gmail',
          displayName: 'Gmail',
          androidPackages: ['com.google.android.gm'],
          domains: ['mail.google.com'],
        ),
        CategoryService(
          id: 'google_docs',
          displayName: 'Google Docs',
          androidPackages: ['com.google.android.apps.docs.editors.docs'],
          domains: ['docs.google.com'],
        ),
        CategoryService(
          id: 'google_drive',
          displayName: 'Google Drive',
          androidPackages: ['com.google.android.apps.docs'],
          domains: ['drive.google.com'],
        ),
        CategoryService(
          id: 'google_calendar',
          displayName: 'Google Calendar',
          androidPackages: ['com.google.android.calendar'],
          domains: ['calendar.google.com'],
        ),
        CategoryService(
          id: 'google_keep',
          displayName: 'Google Keep',
          androidPackages: ['com.google.android.keep'],
          domains: ['keep.google.com'],
        ),
        CategoryService(
          id: 'notion',
          displayName: 'Notion',
          androidPackages: ['notion.id'],
          domains: ['notion.so'],
        ),
        CategoryService(
          id: 'slack',
          displayName: 'Slack',
          androidPackages: ['com.Slack'],
          domains: ['slack.com'],
        ),
        CategoryService(
          id: 'teams',
          displayName: 'Microsoft Teams',
          androidPackages: ['com.microsoft.teams'],
          domains: ['teams.microsoft.com'],
        ),
        CategoryService(
          id: 'outlook',
          displayName: 'Outlook',
          androidPackages: ['com.microsoft.office.outlook'],
          domains: ['outlook.live.com', 'outlook.office.com'],
        ),
        CategoryService(
          id: 'todoist',
          displayName: 'Todoist',
          androidPackages: ['com.todoist'],
          domains: ['todoist.com'],
        ),
      ],
    ),
    AppCategory(
      id: 'education',
      displayName: 'Education',
      behavior: AppBehavior.productive,
      services: [
        CategoryService(
          id: 'duolingo',
          displayName: 'Duolingo',
          androidPackages: ['com.duolingo'],
          domains: ['duolingo.com'],
        ),
        CategoryService(
          id: 'khan_academy',
          displayName: 'Khan Academy',
          androidPackages: ['org.khanacademy.android'],
          domains: ['khanacademy.org'],
        ),
        CategoryService(
          id: 'coursera',
          displayName: 'Coursera',
          androidPackages: ['org.coursera.android'],
          domains: ['coursera.org'],
        ),
        CategoryService(
          id: 'udemy',
          displayName: 'Udemy',
          androidPackages: ['com.udemy.android'],
          domains: ['udemy.com'],
        ),
        CategoryService(
          id: 'wikipedia',
          displayName: 'Wikipedia',
          androidPackages: ['org.wikipedia'],
          domains: ['wikipedia.org'],
        ),
        CategoryService(
          id: 'physics_wallah',
          displayName: 'Physics Wallah',
          androidPackages: ['xyz.penpencil.physicswala'],
          domains: ['pw.live'],
        ),
      ],
    ),
  ];
}
