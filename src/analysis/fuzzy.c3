module lsp;

// Case-insensitive subsequence ("fuzzy") matching for completion candidates:
// a candidate matches when every pattern character occurs in it, in order, but
// not necessarily adjacently — "flt" matches "float". Every matched candidate
// also gets a rank, so the caller can order them by how good the match is and
// keep only the best.
// 
// Lower values are better for every numeric field.
// 
// Ranking order:
// 
// 1. Exact match
// 2. Prefix match
// 3. Contiguous match — the candidate literally contains the pattern
// 4. Earlier first matched character
// 5. Fewer skipped characters
// 6. Earlier matched characters overall
// 7. Shorter candidate
// 
// Contiguity is compared before position, but only as "contiguous or not". Ranking
// by position first buries a candidate that literally contains the pattern under any
// candidate whose stray leading letter happens to line up: for "sink",
// strip_comment_markers (s-tr-i-p_comme-n-t_mar-k-ers) would beat CompletionSink.
// Comparing the gap *count* before position overcorrects the other way, ranking
// module_filter above float for "flt" — so gaps only break ties below position.
struct FuzzyRank
{
	bool matched;

	// 0 = exact
	// 1 = prefix
	// 2 = subsequence
	int tier;

	sz gaps;
	sz first;
	sz position_sum;
	sz candidate_length;
}

// Patterns shorter than this only match as a prefix. A single-character
// subsequence match means nothing more than "contains this letter", which
// would drown the completion list — and because collection stops at
// MAX_DOC_IDENTS distinct names, that flood can push genuine prefix matches
// out of the response entirely.
const sz FUZZY_MIN_PATTERN = 2;

fn char fuzzy_ascii_lower(char c) @private
{
	if (c >= 'A' && c <= 'Z')
	{
		return c + 32;
	}

	return c;
}

// Index of the earliest case-insensitive occurrence of `pattern` in `candidate`,
// or -1 when it does not occur contiguously.
fn sz fuzzy_first_occurrence_ci(String candidate, String pattern) @private
{
	if (pattern.len == 0 || pattern.len > candidate.len) return -1;

	for (sz start = 0; start + pattern.len <= candidate.len; start++)
	{
		sz i = 0;
		while (i < pattern.len && fuzzy_ascii_lower(candidate[start + i]) == fuzzy_ascii_lower(pattern[i]))
		{
			i++;
		}
		if (i == pattern.len) return start;
	}

	return -1;
}

fn FuzzyRank fuzzy_rank_ci(String candidate, String pattern)
{
	FuzzyRank rank = { .matched = false, .tier = 2, .gaps = 0, .first = 0, .position_sum = 0, .candidate_length = candidate.len, };

	if (pattern.len == 0)
	{
		rank.matched = true;
		return rank;
	}

	if (candidate.len == 0 || pattern.len > candidate.len)
	{
		return rank;
	}

	// A contiguous occurrence is the best score any subsequence match can reach — no
	// skipped characters at all — and the earliest one is the best of those, so it is
	// worth looking for directly. Greedy left-to-right matching finds it only when no
	// stray earlier character pulls the match apart first.
	sz at = fuzzy_first_occurrence_ci(candidate, pattern);
	if (at >= 0)
	{
		rank.matched = true;
		rank.first = at;
		rank.position_sum = pattern.len * at + pattern.len * (pattern.len - 1) / 2;
		if (at == 0) rank.tier = candidate.len == pattern.len ? 0 : 1;

		// A pattern this short can only ever match contiguously, so this is the one
		// place the prefix-only rule for short patterns has to be applied.
		if (rank.tier == 2 && pattern.len < FUZZY_MIN_PATTERN) rank.matched = false;
		return rank;
	}

	// No contiguous occurrence, so this is a scattered match and can only be tier 2.
	// Take the earliest one: that minimizes `first` and `position_sum`, though not
	// necessarily `gaps` — a candidate holding a tighter match further along can score
	// slightly worse than it deserves. The tight matches worth protecting are exactly
	// the contiguous ones handled above, so the approximation is left in place.
	sz pattern_index     = 0;
	sz first_position    = 0;
	sz previous_position = 0;
	sz gaps              = 0;
	sz position_sum      = 0;
	bool have_match      = false;

	for (sz candidate_index = 0; candidate_index < candidate.len; candidate_index++)
	{
		if (fuzzy_ascii_lower(candidate[candidate_index]) != fuzzy_ascii_lower(pattern[pattern_index]))
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
		position_sum += candidate_index;
		pattern_index++;

		if (pattern_index < pattern.len) continue;

		rank.matched = true;
		rank.gaps = gaps;
		rank.first = first_position;
		rank.position_sum = position_sum;
		return rank;
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

	// A candidate that contains the pattern outright beats any scattered match,
	// however early the scattered one happens to start.
	bool a_contiguous = a.gaps == 0;
	bool b_contiguous = b.gaps == 0;
	if (a_contiguous != b_contiguous)
	{
		return a_contiguous;
	}

	if (a.first != b.first)
	{
		return a.first < b.first;
	}

	if (a.gaps != b.gaps)
	{
		return a.gaps < b.gaps;
	}

	if (a.position_sum != b.position_sum)
	{
		return a.position_sum < b.position_sum;
	}

	return a.candidate_length < b.candidate_length;
}
