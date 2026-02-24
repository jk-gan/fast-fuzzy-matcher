package main

import "core:fmt"
import "core:testing"

MATCH_SCORE :: 12
MISMATCH_PENALTY :: 6

GAP_OPEN_PENALTY :: 5
GAP_EXTEND_PENALTY :: 1

saturating_sub :: proc(a, b: u16) -> u16 { return a >= b ? a - b : 0 }

is_subsequence :: proc(needle, haystack: string) -> bool {
	ni := 0
	for hi in 0 ..< len(haystack) {
		if ni < len(needle) && needle[ni] == haystack[hi] {
			ni += 1
		}
	}
	return ni == len(needle)
}

smith_waterman :: proc(needle, haystack: string) -> u16 {
	needle_len := len(needle)
	haystack_len := len(haystack)
	if needle_len == 0 || haystack_len == 0 do return 0
	if !is_subsequence(needle, haystack) do return 0

	rows := needle_len + 1
	cols := haystack_len + 1

	score_matrix := make([]u16, rows * cols)
	defer delete(score_matrix)

	haystack_gap_matrix := make([]u16, rows * cols)
	defer delete(haystack_gap_matrix)

	for i in 1..=needle_len {
		for j in 1 ..=haystack_len {
			diagonal := score_matrix[(i - 1) * cols + (j - 1)]
			if needle[i - 1] == haystack[j - 1] {
				diagonal += MATCH_SCORE
			} else {
				diagonal = saturating_sub(diagonal, MISMATCH_PENALTY)
			}

			// Gap in haystack (left): skipping haystack chars
			haystack_gap_matrix[i * cols + j] = max(
				saturating_sub(score_matrix[i * cols + (j - 1)], GAP_OPEN_PENALTY),
				saturating_sub(haystack_gap_matrix[i * cols + (j - 1)], GAP_EXTEND_PENALTY),
			)

			score_matrix[i * cols + j] = max(diagonal, haystack_gap_matrix[i * cols + j])
		}

	}

	best: u16 = 0
	for j in 0..=haystack_len {
		best = max(best, score_matrix[needle_len * cols + j])
	}
	return best
}

main :: proc() {
	fmt.println("Hello, World!")
	fmt.println(smith_waterman("foo", "foobar"))
	fmt.println(smith_waterman("fob", "foobar"))
	fmt.println(smith_waterman("xyz", "foobar"))
	fmt.println(smith_waterman("fb", "foobar"))
}

@(test)
test_no_match :: proc(t: ^testing.T) {
	testing.expect_value(t, smith_waterman("xyz", "foobar"), 0)
	testing.expect_value(t, smith_waterman("abc", "def"), 0)
}

@(test)
test_exact_match :: proc(t: ^testing.T) {
	testing.expect_value(t, smith_waterman("foo", "foo"), u16(MATCH_SCORE * 3))
}

@(test)
test_empty_inputs :: proc(t: ^testing.T) {
	testing.expect_value(t, smith_waterman("", "foobar"), 0)
	testing.expect_value(t, smith_waterman("foo", ""), 0)
	testing.expect_value(t, smith_waterman("", ""), 0)
}

@(test)
test_affine_gap_one_long_gap_beats_multiple_short_gaps :: proc(t: ^testing.T) {
	// "fbar" on "foobar": 1 gap skipping "oo"
	one_gap := smith_waterman("fbar", "foobar")
	// "fbr" on "fxoxobar": 2 gaps
	two_gaps := smith_waterman("fbr", "fxbxr")
	testing.expect(t, one_gap > two_gaps, fmt.tprintf("one gap (%d) should beat two gaps (%d)", one_gap, two_gaps))
}

@(test)
test_affine_gap_shorter_gap_scores_higher :: proc(t: ^testing.T) {
	short_gap := smith_waterman("abcd", "abc_d")     // 3 matches, then gap of 1
	long_gap := smith_waterman("abcd", "abc___d")   // 3 matches, then gap of 3
	testing.expect(t, short_gap > long_gap, fmt.tprintf("short gap (%d) should beat long gap (%d)", short_gap, long_gap))
}

@(test)
test_contiguous_match_beats_gap :: proc(t: ^testing.T) {
	contiguous := smith_waterman("foo", "foobar")   // no gaps
	with_gap := smith_waterman("for", "foobar")     // gap skipping "ba"
	testing.expect(t, contiguous > with_gap, fmt.tprintf("contiguous (%d) should beat gap (%d)", contiguous, with_gap))
}

@(test)
test_needle_longer_than_haystack :: proc(t: ^testing.T) {
	testing.expect_value(t, smith_waterman("foobar", "foo"), 0)
	testing.expect_value(t, smith_waterman("abcdef", "abc"), 0)
}

@(test)
test_single_character :: proc(t: ^testing.T) {
	testing.expect_value(t, smith_waterman("f", "f"), u16(MATCH_SCORE))
	testing.expect_value(t, smith_waterman("f", "abcf"), u16(MATCH_SCORE))
	testing.expect_value(t, smith_waterman("x", "abc"), 0)
}

@(test)
test_full_exact_match :: proc(t: ^testing.T) {
	testing.expect_value(t, smith_waterman("foobar", "foobar"), u16(MATCH_SCORE * 6))
}

@(test)
test_subsequence_multiple_gaps :: proc(t: ^testing.T) {
	// "ace" in "abcde": match a, skip b, match c, skip d, match e — two gaps
	score := smith_waterman("ace", "abcde")
	exact := smith_waterman("ace", "ace")
	testing.expect(t, score > 0, "subsequence should match")
	testing.expect(t, exact > score, fmt.tprintf("exact (%d) should beat subsequence with gaps (%d)", exact, score))
}

@(test)
test_match_at_end :: proc(t: ^testing.T) {
	score := smith_waterman("bar", "foobar")
	testing.expect_value(t, score, u16(MATCH_SCORE * 3))
}

@(test)
test_match_at_start :: proc(t: ^testing.T) {
	score := smith_waterman("foo", "foobar")
	testing.expect_value(t, score, u16(MATCH_SCORE * 3))
}

@(test)
test_repeated_characters :: proc(t: ^testing.T) {
	// "aa" in "aaba" — should match the two consecutive a's for best score
	consecutive := smith_waterman("aa", "aaba")
	spaced := smith_waterman("aa", "a__a")
	testing.expect(t, consecutive > spaced, fmt.tprintf("consecutive (%d) should beat spaced (%d)", consecutive, spaced))
}

@(test)
test_typo_no_match :: proc(t: ^testing.T) {
	// "fxo" is not a subsequence of "foo", so no match
	testing.expect_value(t, smith_waterman("fxo", "foo"), 0)
	testing.expect_value(t, smith_waterman("baz", "foobar"), 0)
}

@(test)
test_affine_gap_extend_cost :: proc(t: ^testing.T) {
	// gap of 2 should cost GAP_OPEN + GAP_EXTEND = 6
	// gap of 3 should cost GAP_OPEN + 2*GAP_EXTEND = 7
	// so gap of 3 should score only 1 less than gap of 2
	gap2 := smith_waterman("abcd", "abc__d")
	gap3 := smith_waterman("abcd", "abc___d")
	diff := gap2 - gap3
	testing.expect_value(t, diff, u16(GAP_EXTEND_PENALTY))
}

@(test)
test_scattered_matches :: proc(t: ^testing.T) {
	// "fbr" on "foobar": f matches, skip oo, b matches, skip a, r matches — 2 gaps
	scattered := smith_waterman("fbr", "foobar")
	testing.expect(t, scattered > 0, "scattered match should produce a score")
	contiguous := smith_waterman("foo", "foobar")
	testing.expect(t, contiguous > scattered, fmt.tprintf("contiguous (%d) should beat scattered (%d)", contiguous, scattered))
}

@(test)
test_ranking_file_picker :: proc(t: ^testing.T) {
	needle := "main"
	candidates := []struct{ path: string, expected_rank: int }{
		{ "main.odin",           1 },  // exact prefix
		{ "src/main.odin",       2 },  // exact match within path
		{ "domain_manager.odin", 3 },  // scattered match: m-a-i-n
		{ "readme.txt",          4 },  // poor/no match
	}

	scores: [4]u16
	for c, i in candidates {
		scores[i] = smith_waterman(needle, c.path)
	}

	// Each higher-ranked candidate should score strictly higher
	for i in 1 ..< len(candidates) {
		testing.expect(
			t,
			scores[i - 1] >= scores[i],
			fmt.tprintf("'%s' (%d) should rank above '%s' (%d)",
				candidates[i - 1].path, scores[i - 1],
				candidates[i].path, scores[i]),
		)
	}
}

@(test)
test_ranking_function_search :: proc(t: ^testing.T) {
	needle := "sw"
	candidates := []string{
		"swap",            // s + w contiguous at start — best
		"show_widget",     // s...w gap of 4 — decent
		"smith_waterman",  // s...w gap of 5 — worse
		"foobar",          // no match
	}

	scores: [4]u16
	for c, i in candidates {
		scores[i] = smith_waterman(needle, c)
	}

	for i in 1 ..< len(candidates) {
		testing.expect(
			t,
			scores[i - 1] >= scores[i],
			fmt.tprintf("'%s' (%d) should rank above '%s' (%d)",
				candidates[i - 1], scores[i - 1],
				candidates[i], scores[i]),
		)
	}
}
