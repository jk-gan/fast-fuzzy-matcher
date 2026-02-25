package main

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:testing"
import "core:thread"
import "core:mem"
import "base:intrinsics"

MATCH_SCORE :: 12
MISMATCH_PENALTY :: 6

GAP_OPEN_PENALTY :: 5
GAP_EXTEND_PENALTY :: 1

MAX_HAYSTACK :: 512

Work_Dispatcher :: struct {
	query: string,
	lines: []string,
	chunk_size: int,
	chunk_count: int,
	next_chunk_index: int,
}

Worker_Result :: struct {
	dispacther: ^Work_Dispatcher,
	local_candidates: [dynamic]Candidate,
}

worker_match_lines :: proc(result: ^Worker_Result) {
	dispatcher := result.dispacther
	query := dispatcher.query
	query_len := len(query)

	 // Thread-local arena: reused for every line this worker processes
    arena_buffer := make([]byte, 2 * (query_len + 1) * (MAX_HAYSTACK + 1) * size_of(u16))
    defer delete(arena_buffer)

    arena: mem.Arena
    mem.arena_init(&arena, arena_buffer)
    arena_allocator := mem.arena_allocator(&arena)

	for {
		chunk_index := intrinsics.atomic_add(&dispatcher.next_chunk_index, 1)
		if chunk_index >= dispatcher.chunk_count {
			break
		}

		start_index := chunk_index * dispatcher.chunk_size
		end_index := min(start_index + dispatcher.chunk_size, len(dispatcher.lines))

		for line in dispatcher.lines[start_index:end_index] {
		   score: u16

            // Arena buffer is sized for MAX_HAYSTACK only.
            // Fallback for longer lines to avoid arena overflow.
            if len(line) <= MAX_HAYSTACK {
                    score = smith_waterman(query, line, arena_allocator)
                    mem.arena_free_all(&arena)
            } else {
                    score = smith_waterman(query, line)
            }

			if score > 0 {
				append(&result.local_candidates, Candidate{
					line = line,
					score = score,
				})
			}
		}
	}
}

Candidate :: struct {
	line:  string,
	score: u16
}

saturating_sub :: proc(a, b: u16) -> u16 { return a >= b ? a - b : 0 }

is_subsequence :: proc(needle, haystack: string) -> bool {
	if len(needle) > len(haystack) do return false

	ni := 0
	for hi in 0 ..< len(haystack) {
		if ni < len(needle) && needle[ni] == haystack[hi] {
			ni += 1
		}
	}
	return ni == len(needle)
}

smith_waterman :: proc(needle, haystack: string, allocator := context.allocator) -> u16 {
	needle_len := len(needle)
	haystack_len := len(haystack)
	if needle_len == 0 || haystack_len == 0 do return 0
	if !is_subsequence(needle, haystack) do return 0

	rows := needle_len + 1
	cols := haystack_len + 1

	score_matrix := make([]u16, rows * cols, allocator)
	// defer delete(score_matrix)
	haystack_gap_matrix := make([]u16, rows * cols, allocator)
	// defer delete(haystack_gap_matrix)

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
	args := os.args
	fmt.println("Args:", args)
	if len(args) < 2 {
		fmt.eprintln("Usage: fast-fuzzy-matcher <query> [threads]")
		os.exit(1)
	}
	needle := args[1]
	thread_count := max(1, os.get_processor_core_count())
	for arg in args[2:] {
		parsed_threads, ok := strconv.parse_int(arg)
		if !ok || parsed_threads <= 0 {
			fmt.eprintln("Invalid thread count:", arg, "(must be a positive integer)")
			os.exit(1)
		}
		thread_count = parsed_threads
	}

	fmt.println("Searching for:", needle, "with", thread_count, "threads")

	reader: bufio.Scanner
	bufio.scanner_init(&reader, os.to_stream(os.stdin))
	defer bufio.scanner_destroy(&reader)

	all_lines: [dynamic]string
	defer {
		for line in all_lines do delete(line)
		delete(all_lines)
	}

	for bufio.scanner_scan(&reader) {
		current_line := bufio.scanner_text(&reader)
		append(&all_lines, strings.clone(current_line))
	}

	chunk_size := 512

	dispatcher := Work_Dispatcher{
		query = needle,
		lines = all_lines[:],
		chunk_size = chunk_size,
		chunk_count = (len(all_lines) + chunk_size - 1) / chunk_size,
		next_chunk_index = 0,
	}

	worker_results := make([]Worker_Result, thread_count)
	defer {
		for result in worker_results do delete(result.local_candidates)
		delete(worker_results)
	}

	threads := make([]^thread.Thread, thread_count)
	defer delete(threads)

	for i in 0..<thread_count {
		worker_results[i].dispacther = &dispatcher
		threads[i] = thread.create_and_start_with_poly_data(&worker_results[i], worker_match_lines)
	}

	for t in threads {
		thread.destroy(t)
	}

	// Merge results
	candidates: [dynamic]Candidate
	defer delete(candidates)

	for result in worker_results {
		for c in result.local_candidates {
			append(&candidates, c)
		}
	}

	// total := 0
	// for bufio.scanner_scan(&reader) {
	// 	current_line := bufio.scanner_text(&reader)
	// 	total += 1

	// 	score := smith_waterman(needle, current_line)
	// 	if score > 0 {
	// 		append(&candidates, Candidate{
	// 			line = strings.clone(current_line),
	// 			score = score
	// 		})
	// 	}
	// 	// mem.arena_free_all(&arena)
	// }

	slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool {
		return a.score > b.score
	})

	for c in candidates {
		fmt.println(c.line)
	}

	fmt.printfln("Found %d candidates from %d", len(candidates), len(all_lines))
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
