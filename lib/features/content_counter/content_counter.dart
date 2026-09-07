/// content_counter feature — the short-video / reel awareness counter.
///
/// Public surface (other features import ONLY this barrel; never reach into
/// data/ or presentation/ internals):
/// - domain entities + repository contracts (count, styles, bubble, widget);
/// - `ContentCounterCubit` / `CounterAppearanceCubit` — provided app-wide in
///   `main.dart`; screens read them from context;
/// - `BubblePreview`, `WidgetPreview` — the counter's embeddable surfaces
///   (Appearance hub previews). The Activity tab reads the cubit directly.
library;

export 'content_counter_appearance/presentation/widgets/bubble_preview.dart';
export 'content_counter_appearance/presentation/widgets/widget_palette.dart';
export 'content_counter_appearance/presentation/widgets/widget_preview.dart';
export 'content_counter_bubble/domain/entities/bubble_style.dart';
export 'content_counter_bubble/domain/repositories/bubble_repository.dart';
export 'content_counter_core/domain/entities/app_content_count.dart';
export 'content_counter_core/domain/entities/content_count.dart';
export 'content_counter_core/domain/entities/counter_appearance.dart';
export 'content_counter_core/domain/entities/counter_style_enums.dart';
export 'content_counter_core/domain/repositories/content_counter_repository.dart';
export 'content_counter_core/domain/repositories/counter_appearance_repository.dart';
export 'content_counter_core/domain/usage_ladder.dart';
export 'content_counter_core/presentation/content_counter_cubit.dart';
export 'content_counter_core/presentation/counter_appearance_cubit.dart';
export 'home_content_counter/domain/entities/widget_style.dart';
export 'home_content_counter/domain/repositories/home_widget_repository.dart';
