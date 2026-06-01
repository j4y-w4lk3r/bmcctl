package secrets

import (
	"strings"
	"testing"
)

// TestParseOpItemID covers the exact regression the user hit:
// `op item create --format json` emits PRETTY-PRINTED JSON
// (whitespace between `:` and the value), which the previous
// hand-rolled `extractField(out, "\"id\":\"")` would silently
// miss. We pin a realistic op response here so the bug cannot
// silently come back.
func TestParseOpItemID(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		wantID  string
		wantErr string // substring; "" means no error
	}{
		{
			name: "pretty-printed (the regression)",
			input: `{
  "id": "abc123itemuuid456",
  "title": "BMC – bmc-54",
  "version": 1,
  "vault": {
    "id": "g3irkmq3taou5ko6gwxwlkcjd4",
    "name": "0-iot+network+yk"
  },
  "category": "LOGIN",
  "urls": [{"href": "https://192.168.1.54/"}]
}`,
			wantID: "abc123itemuuid456",
		},
		{
			name:   "compact (other op versions)",
			input:  `{"id":"compactuuid","title":"BMC – x","vault":{"id":"vault-id","name":"V"}}`,
			wantID: "compactuuid",
		},
		{
			name: "id deeper than vault.id but top-level still wins",
			input: `{
  "title": "BMC – x",
  "vault": {"id":"vaultidwrong","name":"V"},
  "id": "correctitemid"
}`,
			wantID: "correctitemid",
		},
		{
			name:    "garbled output",
			input:   `op output that is not JSON at all`,
			wantErr: "was not JSON",
		},
		{
			name:    "valid JSON but missing id",
			input:   `{"title":"BMC – x"}`,
			wantErr: "no \"id\" field",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseOpItemID(c.input)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want substring %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if got != c.wantID {
				t.Errorf("id = %q, want %q", got, c.wantID)
			}
		})
	}
}

// TestFindOpItemByTitle covers the same parse-via-encoding/json fix
// applied to `op item list`, including the "previous adopt attempt
// left an orphan" recovery case where re-running `bmcctl adopt`
// must find that orphan instead of creating a duplicate.
func TestFindOpItemByTitle(t *testing.T) {
	const listOut = `[
  {"id":"item-A","title":"Wi-Fi network"},
  {"id":"item-B","title":"BMC – bmc-54","vault":{"id":"v1","name":"0-iot+network+yk"}},
  {"id":"item-C","title":"BMC – bmc-55"}
]`
	got, err := findOpItemByTitle(listOut, "BMC – bmc-54")
	if err != nil {
		t.Fatal(err)
	}
	if got != "item-B" {
		t.Errorf("id = %q, want item-B", got)
	}

	got, err = findOpItemByTitle(listOut, "bmc – BMC-54") // case-insensitive
	if err != nil {
		t.Fatal(err)
	}
	if got != "item-B" {
		t.Errorf("case-insensitive lookup failed: %q", got)
	}

	got, err = findOpItemByTitle(listOut, "nope")
	if err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Errorf("expected empty for missing, got %q", got)
	}

	if _, err := findOpItemByTitle("not-json", "x"); err == nil {
		t.Errorf("expected parse error on garbled input")
	}
}
