package bmc

import (
	"crypto/rand"
	"errors"
	"math/big"
	"strings"
)

// Password character classes. We intentionally exclude characters that
// are ambiguous in monospace fonts (Il10O) and shell-special characters
// that bite people in scripts (` \ $ " ' \).
const (
	upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
	lower   = "abcdefghijkmnpqrstuvwxyz"
	digits  = "23456789"
	symbols = "!@#%^&*()-_=+[]{};:,.<>?/~"
)

// GeneratePassword returns a cryptographically random password of the
// requested length. The result is guaranteed to contain at least one
// character from each class so it satisfies MegaRAC's strength policy
// (≥1 upper, ≥1 lower, ≥1 digit, ≥1 symbol).
//
// length must be >= 12. Anything below is rejected because it's too
// weak for a control-plane password.
func GeneratePassword(length int) (string, error) {
	if length < 12 {
		return "", errors.New("password length must be at least 12")
	}
	alphabet := upper + lower + digits + symbols
	out := make([]byte, length)

	// Seed with one of each class so we don't roll a result that
	// happens to omit one (small but nonzero probability for short pws).
	out[0] = pickByte(upper)
	out[1] = pickByte(lower)
	out[2] = pickByte(digits)
	out[3] = pickByte(symbols)
	for i := 4; i < length; i++ {
		out[i] = pickByte(alphabet)
	}
	shuffle(out)
	return string(out), nil
}

func pickByte(s string) byte {
	n, err := rand.Int(rand.Reader, big.NewInt(int64(len(s))))
	if err != nil {
		// crypto/rand reading the OS RNG should never fail. If it
		// does we panic — a weak BMC password is unacceptable.
		panic("crypto/rand: " + err.Error())
	}
	return s[n.Int64()]
}

// shuffle performs a Fisher–Yates shuffle using crypto/rand.
func shuffle(b []byte) {
	for i := len(b) - 1; i > 0; i-- {
		j, err := rand.Int(rand.Reader, big.NewInt(int64(i+1)))
		if err != nil {
			panic("crypto/rand: " + err.Error())
		}
		b[i], b[int(j.Int64())] = b[int(j.Int64())], b[i]
	}
}

// MaskPassword returns a redacted form for logs (first 2 + last 2 chars
// + length). Used only for diagnostics; never log the raw password.
func MaskPassword(pw string) string {
	if len(pw) <= 6 {
		return strings.Repeat("*", len(pw))
	}
	return pw[:2] + strings.Repeat("*", len(pw)-4) + pw[len(pw)-2:]
}
