package bmc

import "testing"

// TestExpandCIDR_Sizes spot-checks several common CIDRs.
func TestExpandCIDR_Sizes(t *testing.T) {
	cases := []struct {
		cidr string
		want int // expected number of addresses (excluding network/broadcast)
	}{
		{"192.168.1.0/24", 254},
		{"192.168.1.0/29", 6}, // 8 - 2
		{"10.0.0.0/22", 1022}, // 1024 - 2
	}
	for _, c := range cases {
		ips, err := expandCIDR(c.cidr)
		if err != nil {
			t.Errorf("%s: %v", c.cidr, err)
			continue
		}
		if len(ips) != c.want {
			t.Errorf("%s: got %d ips, want %d", c.cidr, len(ips), c.want)
		}
	}
}

// TestExpandCIDR_24Boundaries verifies the first and last host of a /24
// match what users expect (.1 and .254 — *not* .0 / .255).
func TestExpandCIDR_24Boundaries(t *testing.T) {
	ips, err := expandCIDR("192.168.1.0/24")
	if err != nil {
		t.Fatal(err)
	}
	if ips[0] != "192.168.1.1" {
		t.Errorf("first = %q, want 192.168.1.1", ips[0])
	}
	if ips[len(ips)-1] != "192.168.1.254" {
		t.Errorf("last = %q, want 192.168.1.254", ips[len(ips)-1])
	}
}

// TestExpandCIDR_Refusals confirms we reject malformed input and
// dangerously large ranges (which would mass-scan the internet).
func TestExpandCIDR_Refusals(t *testing.T) {
	cases := []string{
		"",
		"not a cidr",
		"192.168.1.1", // missing /N
		"10.0.0.0/8",  // too large
		"0.0.0.0/0",   // way too large
		"::/0",        // IPv6 unsupported
	}
	for _, c := range cases {
		if _, err := expandCIDR(c); err == nil {
			t.Errorf("expandCIDR(%q) should have failed", c)
		}
	}
}
