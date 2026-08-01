module lsp;

import std::core::dstring;

// Lower values are better for every numeric field.
//
// Ranking order:
//
// 1. Exact match
// 2. Prefix match
// 3. General subsequence match
// 4. Earlier first matched character
// 5. Earlier matched characters overall
// 6. Tighter match span
// 7. Fewer skipped characters
// 8. Shorter candidate
struct FuzzyRank
{
    bool matched;

    // 0 = exact
    // 1 = prefix
    // 2 = subsequence
    int tier;

    sz first;
    sz position_sum;
    sz span;
    sz gaps;
    sz candidate_length;
}

fn char fuzzy_ascii_lower(char c) @private
{
    if (c >= 'A' && c <= 'Z')
    {
	    return c + 32;
    }

    return c;
}

fn bool fuzzy_equal_ci(String a, String b) @private
{
    if (a.len != b.len) return false;

    for (sz i = 0; i < a.len; i++)
    {
	    if (fuzzy_ascii_lower(a[i]) != fuzzy_ascii_lower(b[i]))
	    {
	        return false;
	    }
    }

    return true;
}

// Return the best left-to-right subsequence rank.
//
// Matching the earliest possible occurrence of each pattern character
// minimizes first position, position sum, span, and skipped gaps.
fn FuzzyRank fuzzy_rank_ci(String candidate, String pattern)
{
    FuzzyRank rank = {
	    .matched = false,
	    .tier = 2,
	    .first = 0,
	    .position_sum = 0,
	    .span = 0,
	    .gaps = 0,
	    .candidate_length = candidate.len,
    };

    if (pattern.len == 0)
    {
	    rank.matched = true;
	    return rank;
    }

    if (candidate.len == 0 || pattern.len > candidate.len)
    {
	    return rank;
    }

    sz pattern_index = 0;
    sz first_position = 0;
    sz previous_position = 0;
    sz last_position = 0;
    sz position_sum = 0;
    sz gaps = 0;
    bool have_match = false;

    for (sz candidate_index = 0;
	     candidate_index < candidate.len;
	     candidate_index++)
    {
	    char candidate_char =
	        fuzzy_ascii_lower(candidate[candidate_index]);

	    char pattern_char =
	        fuzzy_ascii_lower(pattern[pattern_index]);

	    if (candidate_char != pattern_char)
	    {
	        continue;
	    }

	    if (!have_match)
	    {
	        first_position = candidate_index;
	        have_match = true;
	    }
	    else
	    {
	        gaps += candidate_index - previous_position - 1;
	    }

	    previous_position = candidate_index;
	    last_position = candidate_index;
	    position_sum += candidate_index;
	    pattern_index++;

	    if (pattern_index == pattern.len)
	    {
	        rank.matched = true;
	        rank.first = first_position;
	        rank.position_sum = position_sum;
	        rank.span = last_position - first_position + 1;
	        rank.gaps = gaps;

	        if (fuzzy_equal_ci(candidate, pattern))
	        {
		        rank.tier = 0;
	        }
	        else if (first_position == 0 &&
			         rank.span == pattern.len)
	        {
		        rank.tier = 1;
	        }

	        return rank;
	    }
    }

    return rank;
}

fn bool fuzzy_match_ci(String candidate, String pattern)
{
    return fuzzy_rank_ci(candidate, pattern).matched;
}

// Return true when A should sort before B.
fn bool fuzzy_rank_better(FuzzyRank a, FuzzyRank b)
{
    if (a.matched != b.matched)
    {
	    return a.matched;
    }

    if (!a.matched)
    {
	    return false;
    }

    if (a.tier != b.tier)
    {
	    return a.tier < b.tier;
    }

    if (a.first != b.first)
    {
	    return a.first < b.first;
    }

    if (a.position_sum != b.position_sum)
    {
	    return a.position_sum < b.position_sum;
    }

    if (a.span != b.span)
    {
	    return a.span < b.span;
    }

    if (a.gaps != b.gaps)
    {
	    return a.gaps < b.gaps;
    }

    return a.candidate_length < b.candidate_length;
}

// Build a fixed-width lexicographic LSP sortText value.
//
// The fields are zero-padded because sortText is compared as text,
// not as a numeric tuple.
fn String fuzzy_sort_text(String candidate, String pattern)
{
    FuzzyRank rank = fuzzy_rank_ci(candidate, pattern);

    if (!rank.matched || pattern.len == 0)
    {
	    return "";
    }

    DString result = dstring::temp();

    result.appendf(
	    "%d:%08d:%08d:%08d:%08d:%08d",
	    rank.tier,
	    rank.first,
	    rank.position_sum,
	    rank.span,
	    rank.gaps,
	    rank.candidate_length
    );

    return result.str_view();
}
