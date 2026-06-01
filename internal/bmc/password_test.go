package bmc

import (
	"strings"
	"testing"
	"unicode"
)

// TestGeneratePassword_Length verifies the output is exactly the
// requested length and that the minimum-length guard fires.
func TestGeneratePassword_Length(t *testing.T) {
	for _, n := range []int{12, 16, 24, 40, 64, 128} {
		pw, err := GeneratePassword(n)
		if err != nil {
			t.Fatalf("len=%d: %v", n, err)
		}
		if len(pw) != n {
			t.Errorf("len=%d: got %d", n, len(pw))
		}
	}
	for _, n := range []int{0, 1, 8, 11} {
		if _, err := GeneratePassword(n); err == nil {
			t.Errorf("len=%d: expected error, got nil", n)
		}
	}
}

// TestGeneratePassword_ClassesPresent guarantees every result includes
// at least one upper, lower, digit, and symbol. This is what MegaRAC's
// password policy enforces; a bug that omitted a class would cause the
// PATCH to fail with cryptic errors only after we'd printed the pw.
func TestGeneratePassword_ClassesPresent(t *testing.T) {
	for i := 0; i < 1000; i++ {
		pw, err := GeneratePassword(12)
		if err != nil {
			t.Fatal(err)
		}
		var hasU, hasL, hasD, hasS bool
		for _, r := range pw {
			switch {
			case unicode.IsUpper(r):
				hasU = true
			case unicode.IsLower(r):
				hasL = true
			case unicode.IsDigit(r):
				hasD = true
			case strings.ContainsRune(symbols, r):
				hasS = true
			}
		}
		if !(hasU && hasL && hasD && hasS) {
			t.Fatalf("iter %d: missing class in %q (U=%v L=%v D=%v S=%v)",
				i, pw, hasU, hasL, hasD, hasS)
		}
	}
}

// TestGeneratePassword_NoAmbiguousChars ensures none of the visually
// confusing characters end up in the output. These chars look identical
// in monospace fonts and are a constant source of "I typed the password
// right" support tickets.
func TestGeneratePassword_NoAmbiguousChars(t *testing.T) {
	// Banned set: the chars the generator deliberately excludes.
	//   - I O l o 1 0  : visually confusing in monospace
	//   - ` \ " ' $    : nasty in shell/JSON contexts
	//   - whitespace   : breaks copy/paste and many UIs
	const banned = "IOlo10`\\\"'$\t\n\r "
	for i := 0; i < 2000; i++ {
		pw, err := GeneratePassword(40)
		if err != nil {
			t.Fatal(err)
		}
		if idx := strings.IndexAny(pw, banned); idx >= 0 {
			t.Fatalf("iter %d: banned char %q at index %d in %q",
				i, pw[idx], idx, pw)
		}
	}
}

// TestGeneratePassword_HighEntropy is a smoke test for randomness. Two
// calls in quick succession should almost never collide. We don't
// formally measure entropy; we just sanity-check that the RNG isn't
// stuck on a constant.
func TestGeneratePassword_HighEntropy(t *testing.T) {
	seen := map[string]struct{}{}
	for i := 0; i < 5000; i++ {
		pw, err := GeneratePassword(40)
		if err != nil {
			t.Fatal(err)
		}
		if _, dup := seen[pw]; dup {
			t.Fatalf("duplicate password in %d iterations: %q", i, pw)
		}
		seen[pw] = struct{}{}
	}
}

// TestMaskPassword renders without leaking the inner bytes of long
// passwords and degrades gracefully for short input.
func TestMaskPassword(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"a", "*"},
		{"abcdef", "******"},
		{"abcdefg", "ab***fg"},
		{"FoobarBaz123!", "Fo*********3!"},
	}
	for _, c := range cases {
		got := MaskPassword(c.in)
		if got != c.want {
			t.Errorf("MaskPassword(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
