// VirtualMedia subsystem of the Redfish client. Used by `bmcctl
// mount-iso` / `eject-iso` and as the foundation of `bmcctl
// install-arch`.
//
// The Redfish anatomy (in case a future me forgets):
//
//	GET  /redfish/v1/Managers/Self/VirtualMedia
//	     -> { Members: [ {@odata.id: ".../VirtualMedia/CD1"}, ... ] }
//	GET  /redfish/v1/Managers/Self/VirtualMedia/<slot>
//	     -> { Id, Image, ImageName, Inserted, WriteProtected,
//	          ConnectedVia, MediaTypes }
//	POST /redfish/v1/Managers/Self/VirtualMedia/<slot>/Actions/VirtualMedia.InsertMedia
//	     body: { "Image": "https://...", "Inserted": true,
//	             "WriteProtected": true }
//	POST /redfish/v1/Managers/Self/VirtualMedia/<slot>/Actions/VirtualMedia.EjectMedia
//	     body: {}
//
// AMI MegaRAC names the slots `CD1`, `CD2`, `Floppy1`, `HD1`. For
// install-arch we want the first one whose MediaTypes contains "CD"
// or "DVD". We expose both raw helpers and a SelectCDSlot convenience
// so the CLI can do the right thing without the user thinking about
// slot IDs.

package bmc

import (
	"context"
	"fmt"
	"strings"
)

// VirtualMediaSlot is the fragment of the Redfish VirtualMedia
// resource that we actually use. The full schema has ~30 fields;
// we only model the ones that matter for mount/eject.
type VirtualMediaSlot struct {
	ID             string   `json:"Id"`
	Name           string   `json:"Name"`
	MediaTypes     []string `json:"MediaTypes"`
	Image          string   `json:"Image"`
	ImageName      string   `json:"ImageName"`
	Inserted       bool     `json:"Inserted"`
	WriteProtected bool     `json:"WriteProtected"`
	ConnectedVia   string   `json:"ConnectedVia"`

	// ODataID is the canonical Redfish path for this slot, e.g.
	// "/redfish/v1/Managers/Self/VirtualMedia/CD1". We capture it
	// so callers can build action URLs without re-deriving them.
	ODataID string `json:"@odata.id"`
}

// IsCD reports whether the slot's MediaTypes advertise CD or DVD
// optical media. Used to pick the right slot when the user just
// says "mount this ISO" without specifying which one.
func (v VirtualMediaSlot) IsCD() bool {
	for _, m := range v.MediaTypes {
		switch strings.ToUpper(m) {
		case "CD", "DVD":
			return true
		}
	}
	return false
}

// virtualMediaCollection is the top-level GET response that lists
// every slot the BMC exposes.
type virtualMediaCollection struct {
	Members []struct {
		ODataID string `json:"@odata.id"`
	} `json:"Members"`
	Count int `json:"Members@odata.count"`
}

const virtualMediaPath = "/redfish/v1/Managers/Self/VirtualMedia"

// ListVirtualMedia walks the collection and returns every slot
// fully resolved. This is one network round-trip per slot, which
// is fine: the BMC has at most a handful (typically 2-4).
func (c *Client) ListVirtualMedia(ctx context.Context) ([]VirtualMediaSlot, error) {
	var col virtualMediaCollection
	status, body, err := c.do(ctx, "GET", virtualMediaPath, nil, &col)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	out := make([]VirtualMediaSlot, 0, len(col.Members))
	for _, m := range col.Members {
		// The collection only carries @odata.id refs; fetch each
		// slot's full body so the caller can see ImageName etc.
		slot, err := c.getSlot(ctx, m.ODataID)
		if err != nil {
			return nil, err
		}
		out = append(out, *slot)
	}
	return out, nil
}

func (c *Client) getSlot(ctx context.Context, path string) (*VirtualMediaSlot, error) {
	var slot VirtualMediaSlot
	status, body, err := c.do(ctx, "GET", path, nil, &slot)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	if slot.ODataID == "" {
		slot.ODataID = path
	}
	return &slot, nil
}

// GetVirtualMediaSlot fetches a single slot by ID (e.g. "CD1").
// Convenience for callers who already know which slot to address.
func (c *Client) GetVirtualMediaSlot(ctx context.Context, id string) (*VirtualMediaSlot, error) {
	return c.getSlot(ctx, virtualMediaPath+"/"+id)
}

// SelectCDSlot returns the first VirtualMedia slot whose MediaTypes
// advertise CD or DVD. Errors if none exist (rare; means the BMC
// isn't exposing virtual optical media at all). For install-arch
// this is the slot the ISO mounts into.
func (c *Client) SelectCDSlot(ctx context.Context) (*VirtualMediaSlot, error) {
	slots, err := c.ListVirtualMedia(ctx)
	if err != nil {
		return nil, err
	}
	for _, s := range slots {
		if s.IsCD() {
			cp := s
			return &cp, nil
		}
	}
	if len(slots) == 0 {
		return nil, fmt.Errorf("BMC exposes no VirtualMedia slots")
	}
	names := make([]string, 0, len(slots))
	for _, s := range slots {
		names = append(names, s.ID)
	}
	return nil, fmt.Errorf("no CD/DVD VirtualMedia slot among %v", names)
}

// InsertMedia mounts the given URL into the slot via Redfish's
// VirtualMedia.InsertMedia action. The HTTPS URL must be reachable
// from the BMC — many BMCs cannot follow redirects or hit hosts
// behind self-signed certs, so the caller is responsible for
// providing a stable, plain-HTTP URL or an HTTPS one with a public
// CA-signed cert.
//
// writeProtected=true mounts the image read-only, which is what you
// want for an installer ISO. Pass false only for live USB
// scenarios (which we do not currently use).
func (c *Client) InsertMedia(ctx context.Context, slotID, imageURL string, writeProtected bool) error {
	if slotID == "" {
		return fmt.Errorf("slotID required")
	}
	if imageURL == "" {
		return fmt.Errorf("imageURL required")
	}
	// TransferProtocolType is technically OPTIONAL per the Redfish
	// schema, but AMI MegaRAC firmware (W680D4U-2L2T/G5 v6.01.0)
	// returns ActionParameterMissing without it. Derive from scheme.
	//
	// AMI quirks observed on real hardware:
	//   - "HTTP" not in AllowedValues; only HTTPS / CIFS / NFS work
	//   - HTTPS rejects self-signed certs at TLS handshake — only
	//     publicly-trusted CA chains (or pre-uploaded BMC-trusted
	//     ones) are accepted. Plain LAN bring-up should use NFS.
	//   - HTTPS requires UserName + Password in the body even if
	//     blank; NFS rejects them as PropertyUnknown.
	//   - URL filenames containing multiple dots (e.g. an embedded
	//     date like 2026.06.04) trigger the AMI URL parser quirk
	//     where Image is mis-extracted; use a simple filename.
	lower := strings.ToLower(imageURL)
	var proto string
	body := map[string]any{
		"Image":          imageURL,
		"Inserted":       true,
		"WriteProtected": writeProtected,
	}
	switch {
	case strings.HasPrefix(lower, "nfs://"):
		proto = "NFS"
	case strings.HasPrefix(lower, "cifs://") || strings.HasPrefix(lower, "smb://"):
		proto = "CIFS"
	case strings.HasPrefix(lower, "https://"):
		proto = "HTTPS"
		body["UserName"] = ""
		body["Password"] = ""
	default:
		proto = "HTTPS"
		body["UserName"] = ""
		body["Password"] = ""
	}
	body["TransferProtocolType"] = proto
	target := virtualMediaPath + "/" + slotID + "/Actions/VirtualMedia.InsertMedia"
	status, errBody, err := c.do(ctx, "POST", target, body, nil)
	if err != nil {
		return err
	}
	if status >= 300 {
		return parseRedfishError(status, errBody)
	}
	return nil
}

// EjectMedia detaches whatever image is currently inserted in the
// slot. Idempotent on most MegaRAC builds — calling Eject when
// nothing is inserted returns 204. We tolerate any 2xx.
func (c *Client) EjectMedia(ctx context.Context, slotID string) error {
	if slotID == "" {
		return fmt.Errorf("slotID required")
	}
	target := virtualMediaPath + "/" + slotID + "/Actions/VirtualMedia.EjectMedia"
	status, errBody, err := c.do(ctx, "POST", target, struct{}{}, nil)
	if err != nil {
		return err
	}
	if status >= 300 {
		return parseRedfishError(status, errBody)
	}
	return nil
}
