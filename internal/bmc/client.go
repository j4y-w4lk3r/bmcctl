// Package bmc is a minimal Redfish client tailored for the AMI MegaRAC
// firmware that ASRock Rack ships on the W680D4U-2L2T/G5 (and most of
// their other server boards).
//
// Why a custom client and not gofish?
//   - gofish pulls in a few hundred kB of schema models we don't need.
//   - We only touch ~6 endpoints. Hand-rolled is < 200 LOC and easier
//     to reason about during the password-change dance.
//
// All connections skip TLS verification because BMCs ship with self-
// signed certs and a fresh-from-factory unit has no way to learn a
// "real" CA. We mitigate by checking the cert subject contains AMI's
// signature string ("MEGARAC" or "AMI") in Verify().
package bmc

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// Client talks to one BMC at one host:port. It's safe for concurrent use.
type Client struct {
	Host     string // e.g. "192.168.1.54"
	Port     int    // 443 by default
	Username string
	Password string

	hc *http.Client
}

// NewClient constructs a client. The HTTP client is configured with
// generous-but-bounded timeouts because BMCs are slow.
func NewClient(host, username, password string) *Client {
	port := 443
	if h, p, err := net.SplitHostPort(host); err == nil {
		host = h
		if pp, err := parsePort(p); err == nil {
			port = pp
		}
	}
	return &Client{
		Host:     host,
		Port:     port,
		Username: username,
		Password: password,
		hc: &http.Client{
			Timeout: 12 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					InsecureSkipVerify: true, // BMC certs are always self-signed
					MinVersion:         tls.VersionTLS12,
				},
				DisableKeepAlives:     true,
				ResponseHeaderTimeout: 8 * time.Second,
			},
		},
	}
}

func parsePort(s string) (int, error) {
	var p int
	_, err := fmt.Sscanf(s, "%d", &p)
	return p, err
}

func (c *Client) baseURL() string {
	if c.Port == 443 {
		return "https://" + c.Host
	}
	return fmt.Sprintf("https://%s:%d", c.Host, c.Port)
}

// VerifyMegaRAC dials TLS on port 443 and asserts the cert subject
// looks like an AMI MegaRAC BMC. We do this before any destructive
// operation (password change) to make sure we're not PATCH-ing some
// random HTTPS server that happens to live at the same IP.
func (c *Client) VerifyMegaRAC(ctx context.Context) error {
	d := &net.Dialer{Timeout: 4 * time.Second}
	addr := fmt.Sprintf("%s:%d", c.Host, c.Port)
	conn, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		return fmt.Errorf("TLS dial %s: %w", addr, err)
	}
	defer conn.Close()
	for _, cert := range conn.ConnectionState().PeerCertificates {
		subj := cert.Subject.String() + " " + cert.Issuer.String()
		if strings.Contains(strings.ToUpper(subj), "MEGARAC") ||
			strings.Contains(strings.ToUpper(subj), "AMI") {
			return nil
		}
	}
	return fmt.Errorf("TLS cert at %s does not look like an AMI MegaRAC BMC", addr)
}

// do is the convenience wrapper around doFull for callers that don't
// need to set request headers or read the response's headers.
func (c *Client) do(ctx context.Context, method, path string, body any, out any) (status int, errBody []byte, err error) {
	status, _, errBody, err = c.doFull(ctx, method, path, body, nil, out)
	return
}

// doFull is the universal request helper. The result body is decoded
// into `out` if non-nil. errBody is populated with the response body
// when the status is not 2xx so the caller can show MegaRAC's
// structured error. respHeaders carries the response headers (for
// callers that need to read ETag etc.).
//
// Setting reqHeaders lets the caller pass e.g. If-Match for a PATCH.
func (c *Client) doFull(
	ctx context.Context, method, path string,
	body any, reqHeaders map[string]string, out any,
) (status int, respHeaders http.Header, errBody []byte, err error) {
	var rdr io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return 0, nil, nil, err
		}
		rdr = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL()+path, rdr)
	if err != nil {
		return 0, nil, nil, err
	}
	if c.Username != "" {
		req.SetBasicAuth(c.Username, c.Password)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range reqHeaders {
		req.Header.Set(k, v)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()
	buf, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return resp.StatusCode, resp.Header, nil, err
	}
	if resp.StatusCode >= 300 {
		return resp.StatusCode, resp.Header, buf, nil
	}
	if out != nil && len(buf) > 0 {
		if err := json.Unmarshal(buf, out); err != nil {
			return resp.StatusCode, resp.Header, buf, fmt.Errorf("decode %s: %w", path, err)
		}
	}
	return resp.StatusCode, resp.Header, nil, nil
}

// MegaRAC returns structured errors of this shape:
//
//	{ "error": { "@Message.ExtendedInfo": [ { "Message":"...","MessageId":"..." } ] } }
//
// ParseRedfishError pulls out the human-readable message and the ID.
type RedfishError struct {
	Status  int
	Message string
	ID      string
}

func (e *RedfishError) Error() string {
	if e.ID != "" {
		return fmt.Sprintf("BMC %d %s: %s", e.Status, e.ID, e.Message)
	}
	return fmt.Sprintf("BMC %d: %s", e.Status, e.Message)
}

// IsPasswordChangeRequired returns true when MegaRAC is refusing to
// answer because the default password has not been rotated yet.
func IsPasswordChangeRequired(err error) bool {
	var re *RedfishError
	if errors.As(err, &re) {
		return strings.Contains(re.ID, "PasswordChangeRequired") ||
			strings.Contains(re.Message, "must be changed")
	}
	return false
}

func parseRedfishError(status int, body []byte) error {
	if len(body) == 0 {
		return &RedfishError{Status: status, Message: "empty body"}
	}
	var wrap struct {
		Error struct {
			Info []struct {
				Message   string `json:"Message"`
				MessageID string `json:"MessageId"`
			} `json:"@Message.ExtendedInfo"`
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &wrap)
	if len(wrap.Error.Info) > 0 {
		return &RedfishError{
			Status:  status,
			Message: wrap.Error.Info[0].Message,
			ID:      wrap.Error.Info[0].MessageID,
		}
	}
	if wrap.Error.Message != "" {
		return &RedfishError{Status: status, Message: wrap.Error.Message, ID: wrap.Error.Code}
	}
	return &RedfishError{Status: status, Message: strings.TrimSpace(string(body))}
}
