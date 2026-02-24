package main

import "core:fmt"

MATCH_SCORE :: 2
MISMATCH_PENALTY :: 1
GAP_PENALTY :: 1

saturating_sub :: proc(a, b: u16) -> u16 { return a >= b ? a - b : 0 }

smith_waterman :: proc(needle, haystack: string) -> u16 {
	needle_len := len(needle)
	haystack_len := len(haystack)
	if needle_len == 0 || haystack_len == 0 do return 0

	rows := needle_len + 1
	cols := haystack_len + 1
	sw_matrix := make([]u16, rows * cols)
	defer delete(sw_matrix)

	for i in 1..=needle_len {
		for j in 1 ..=haystack_len {
			diagonal := sw_matrix[(i - 1) * cols + (j - 1)]
			if needle[i - 1] == haystack[j - 1] {
				diagonal += MATCH_SCORE
			} else {
				diagonal = saturating_sub(diagonal, MISMATCH_PENALTY)
			}

			up := saturating_sub(sw_matrix[(i - 1) * cols + j], GAP_PENALTY)
			left := saturating_sub(sw_matrix[i * cols + (j - 1)], GAP_PENALTY)

			sw_matrix[i * cols + j] = max(diagonal, up, left)
		}

	}

	best: u16 = 0
	for j in 0..=haystack_len {
		best = max(best, sw_matrix[needle_len * cols + j])
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
