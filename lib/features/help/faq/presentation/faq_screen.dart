import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/help/faq/data/faq_data.dart';
import 'package:detoxo/features/help/faq/domain/entities/faq_entry.dart';
import 'package:detoxo/features/help/faq/presentation/faq_cubit.dart';
import 'package:detoxo/features/help/faq/presentation/widgets/faq_expansion_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// A searchable, category-grouped FAQ. The content is static (see
/// `faq_data.dart`); the only state is the search query held by [FaqCubit].
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(create: (_) => FaqCubit(), child: const _FaqView());
  }
}

class _FaqView extends StatelessWidget {
  const _FaqView();

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(title: Text('FAQ')),
      body: BlocBuilder<FaqCubit, String>(
        builder: (context, query) {
          final results = filterFaqs(query);
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.xxl,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: AppSearchField(
                  hintText: 'Search FAQs',
                  onChanged: (v) => context.read<FaqCubit>().search(v),
                ),
              ),
              if (results.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.xxl),
                  child: EmptyState(
                    icon: Icons.search_off,
                    title: 'No results',
                    subtitle:
                        'Try different keywords, or email errorxperts@gmail.com',
                  ),
                )
              else
                // Render each category (in enum order) that has matches.
                for (final category in FaqCategory.values)
                  ..._categorySection(context, category, results),
            ],
          );
        },
      ),
    );
  }

  /// A section header + its matching entries, or nothing when the category has
  /// no matches for the current query.
  List<Widget> _categorySection(
    BuildContext context,
    FaqCategory category,
    List<FaqEntry> results,
  ) {
    final entries = results.where((e) => e.category == category).toList();
    if (entries.isEmpty) return const [];
    return [
      SectionHeader(category.label),
      for (final entry in entries) FaqExpansionTile(entry: entry),
    ];
  }
}
