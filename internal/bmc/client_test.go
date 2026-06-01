package bmc

import (
	"errors"
	"testing"
)

// TestParseRedfishError covers the three shapes MegaRAC returns:
//   - { "error": { "@Message.ExtendedInfo": [...] } }  ← real AMI shape
//   - { "error": { "code": "...", "message": "..." } }  ← simpler shape
//   - non-JSON body                                    ← fall through
func TestParseRedfishError(t *testing.T) {
	pcrBody := []byte(`{"error":{"@Message.ExtendedInfo":[{"Message":"The password provided for this account must be changed before access is granted.","MessageId":"Base.1.12.PasswordChangeRequired"}]}}`)
	err := parseRedfishError(403, pcrBody)
	if err == nil {
		t.Fatal("expected error")
	}
	if !IsPasswordChangeRequired(err) {
		t.Errorf("expected IsPasswordChangeRequired=true, got %v", err)
	}

	flatBody := []byte(`{"error":{"code":"Security.1.0.AccessDenied","message":"not allowed"}}`)
	err = parseRedfishError(403, flatBody)
	var re *RedfishError
	if !errors.As(err, &re) {
		t.Fatalf("expected RedfishError, got %T", err)
	}
	if re.ID != "Security.1.0.AccessDenied" || re.Message != "not allowed" {
		t.Errorf("unexpected: %+v", re)
	}

	junkBody := []byte(`<html>500 oh no</html>`)
	err = parseRedfishError(500, junkBody)
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.As(err, &re) {
		t.Fatalf("expected RedfishError, got %T", err)
	}
	if re.Status != 500 {
		t.Errorf("Status = %d, want 500", re.Status)
	}
}

// TestFormatPower normalises user-typed action names. We accept "off"
// as an alias for the (slightly scary) Redfish enum "ForceOff" so the
// CLI is friendlier.
func TestFormatPower(t *testing.T) {
	cases := []struct {
		in, want string
		err      bool
	}{
		{"on", "On", false},
		{"On", "On", false},
		{"off", "ForceOff", false},
		{"FORCEOFF", "ForceOff", false},
		{"graceful", "GracefulShutdown", false},
		{"shutdown", "GracefulShutdown", false},
		{"cycle", "PowerCycle", false},
		{"reset", "ForceRestart", false},
		{"restart", "ForceRestart", false},
		{"graceful-restart", "GracefulRestart", false},
		{"nmi", "Nmi", false},
		{"floof", "", true},
		{"", "", true},
	}
	for _, c := range cases {
		got, err := FormatPower(c.in)
		if c.err {
			if err == nil {
				t.Errorf("FormatPower(%q) should error", c.in)
			}
			continue
		}
		if err != nil {
			t.Errorf("FormatPower(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("FormatPower(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
