// Package testmegarac is an HTTPS mock of the AMI MegaRAC BMC firmware
// that ASRock Rack ships. It is intended for tests — *do not* import
// it from production code.
//
// The mock implements just enough of the Redfish surface that bmcctl
// touches:
//
//   - GET  /redfish/v1/                              (always open)
//   - GET  /redfish/v1/Systems/Self                  (gated)
//   - GET  /redfish/v1/Chassis/Self                  (gated)
//   - GET  /redfish/v1/Managers/Self                 (gated)
//   - GET  /redfish/v1/Chassis/Self/Thermal          (gated)
//   - PATCH /redfish/v1/AccountService/Accounts/4    (changes pw + clears gate)
//   - POST /redfish/v1/Systems/Self/Actions/ComputerSystem.Reset (power)
//
// "Gated" endpoints behave like the real MegaRAC: when the admin
// password is still the factory default (admin/admin), the server
// returns 403 with @Message.ExtendedInfo[0].MessageId =
// "Base.1.12.PasswordChangeRequired". After a successful PATCH the
// gate is cleared and the same endpoints respond normally.
//
// The TLS cert is generated on Start() with a subject containing
// "MEGARAC" so the real client's VerifyMegaRAC() passes.
package testmegarac

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"
)

// Server is a running mock MegaRAC.
type Server struct {
	URL  string // https://127.0.0.1:NNNNN
	Host string // 127.0.0.1:NNNNN — pass to bmc.NewClient
	Cert *x509.Certificate

	srv *httptest.Server

	mu                sync.Mutex
	username          string
	password          string
	passwordChangeReq bool
	powerState        string
	manufacturer      string
	model             string
	sku               string
	serial            string
	biosVersion       string
	cpuModel          string
	cpuCount          int
	memGiB            int
	fwVersion         string
	minPasswordLength int
	maxPasswordLength int
	powerLog          []string
}

// Options configures a new mock. Zero values get sane defaults so a
// test that just wants "a working BMC" can pass Options{}.
type Options struct {
	InitialUsername string // default "admin"
	InitialPassword string // default "admin"
	StartLocked     *bool  // default true (= behaves like factory-fresh)
	PowerState      string // "On" / "Off"; default "On"
	Manufacturer    string // default "ASRockRack"
	Model           string // default "W680D4U-2L2T/G5"
	SKU             string
	SerialNumber    string
	BiosVersion     string
	CPUModel        string
	CPUCount        int
	MemGiB          int
	FirmwareVersion string
	// Password policy. Zero means "use AMI defaults" (8 / 20),
	// matching the W680D4U-2L2T/G5.
	MinPasswordLength int
	MaxPasswordLength int
}

// New starts a mock MegaRAC server on a random localhost port.
func New(opt Options) (*Server, error) {
	s := &Server{
		username:          sval(opt.InitialUsername, "admin"),
		password:          sval(opt.InitialPassword, "admin"),
		powerState:        sval(opt.PowerState, "On"),
		manufacturer:      sval(opt.Manufacturer, "ASRockRack"),
		model:             sval(opt.Model, "W680D4U-2L2T/G5"),
		sku:               opt.SKU,
		serial:            sval(opt.SerialNumber, "TEST-SN-0001"),
		biosVersion:       sval(opt.BiosVersion, "L1.10A"),
		cpuModel:          sval(opt.CPUModel, "Intel(R) Core(TM) i5-13500"),
		cpuCount:          ivalOr(opt.CPUCount, 1),
		memGiB:            ivalOr(opt.MemGiB, 32),
		fwVersion:         sval(opt.FirmwareVersion, "1.00.10"),
		minPasswordLength: ivalOr(opt.MinPasswordLength, 8),
		maxPasswordLength: ivalOr(opt.MaxPasswordLength, 20),
	}
	s.passwordChangeReq = true
	if opt.StartLocked != nil {
		s.passwordChangeReq = *opt.StartLocked
	}

	cert, certPEM, keyPEM, err := makeCert()
	if err != nil {
		return nil, err
	}
	s.Cert = cert

	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	s.srv = httptest.NewUnstartedServer(s.mux())
	s.srv.TLS = &tls.Config{Certificates: []tls.Certificate{tlsCert}}
	s.srv.StartTLS()

	u, _ := splitURL(s.srv.URL)
	s.URL = s.srv.URL
	s.Host = u
	return s, nil
}

// Close shuts down the server.
func (s *Server) Close() { s.srv.Close() }

// ---- inspection helpers (test-only) ----

// Password returns the current admin password as the server sees it.
func (s *Server) Password() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.password
}

// Locked reports whether the server is still gating endpoints behind
// the forced password change.
func (s *Server) Locked() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.passwordChangeReq
}

// PowerLog returns the list of ResetType values seen on the action
// endpoint, in arrival order.
func (s *Server) PowerLog() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.powerLog...)
}

// ---- HTTP layer ----

func (s *Server) mux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/redfish/v1/", s.handleAny)
	return m
}

// handleAny is one big dispatcher so we can share auth + gate logic.
func (s *Server) handleAny(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// Service root is always reachable, even with no/bad creds.
	if path == "/redfish/v1/" {
		s.serveServiceRoot(w)
		return
	}

	if !s.authOK(r) {
		writeError(w, 401, "Security.1.0.AccessDenied", "Authentication failed")
		return
	}

	// PATCH and POST need to go through even when the gate is up;
	// the password-change PATCH is *how* the gate gets cleared.
	switch {
	case r.Method == "GET" && path == "/redfish/v1/AccountService":
		s.serveAccountService(w)
		return
	case r.Method == "GET" && strings.HasPrefix(path, "/redfish/v1/AccountService/Accounts/"):
		s.serveGetAccount(w, r)
		return
	case r.Method == "PATCH" && strings.HasPrefix(path, "/redfish/v1/AccountService/Accounts/"):
		s.serveSetPassword(w, r)
		return
	case r.Method == "POST" && path == "/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset":
		if s.gated(w) {
			return
		}
		s.servePower(w, r)
		return
	}

	if s.gated(w) {
		return
	}

	switch path {
	case "/redfish/v1/Systems/Self":
		s.serveSystem(w)
	case "/redfish/v1/Chassis/Self":
		s.serveChassis(w)
	case "/redfish/v1/Managers/Self":
		s.serveManager(w)
	case "/redfish/v1/Chassis/Self/Thermal":
		s.serveThermal(w)
	default:
		http.NotFound(w, r)
	}
}

// authOK checks HTTP Basic credentials against the current admin/pw.
func (s *Server) authOK(r *http.Request) bool {
	u, p, ok := r.BasicAuth()
	if !ok {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return u == s.username && p == s.password
}

// gated writes the PasswordChangeRequired response and returns true if
// the server is currently gating endpoints.
func (s *Server) gated(w http.ResponseWriter) bool {
	s.mu.Lock()
	locked := s.passwordChangeReq
	s.mu.Unlock()
	if !locked {
		return false
	}
	writeError(w, 403, "Base.1.12.PasswordChangeRequired",
		"The password provided for this account must be changed before access is granted.")
	return true
}

// ---- specific endpoints ----

func (s *Server) serveServiceRoot(w http.ResponseWriter) {
	writeJSON(w, 200, map[string]any{
		"@odata.id":      "/redfish/v1/",
		"@odata.type":    "#ServiceRoot.v1_7_0.ServiceRoot",
		"RedfishVersion": "1.7.0",
		"Product":        "AMI MegaRAC SP-X (testmegarac mock)",
		"UUID":           "00000000-0000-0000-0000-test-megarac",
	})
}

func (s *Server) serveSystem(w http.ResponseWriter) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, 200, map[string]any{
		"@odata.id":    "/redfish/v1/Systems/Self",
		"Manufacturer": s.manufacturer,
		"Model":        s.model,
		"SKU":          s.sku,
		"SerialNumber": s.serial,
		"BiosVersion":  s.biosVersion,
		"PowerState":   s.powerState,
		"ProcessorSummary": map[string]any{
			"Model": s.cpuModel,
			"Count": s.cpuCount,
		},
		"MemorySummary": map[string]any{
			"TotalSystemMemoryGiB": s.memGiB,
		},
		"Status": map[string]any{
			"Health": "OK",
			"State":  "Enabled",
		},
	})
}

func (s *Server) serveChassis(w http.ResponseWriter) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, 200, map[string]any{
		"Manufacturer": s.manufacturer,
		"Model":        s.model,
		"SKU":          s.sku,
		"SerialNumber": s.serial,
		"ChassisType":  "RackMount",
		"PowerState":   s.powerState,
	})
}

func (s *Server) serveManager(w http.ResponseWriter) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, 200, map[string]any{
		"Manufacturer":    "AMI",
		"Model":           "MegaRAC SP-X",
		"FirmwareVersion": s.fwVersion,
		"DateTime":        time.Now().UTC().Format(time.RFC3339),
		"UUID":            "11111111-1111-1111-1111-megarac-mock",
	})
}

func (s *Server) serveThermal(w http.ResponseWriter) {
	writeJSON(w, 200, map[string]any{
		"Temperatures": []map[string]any{
			{"Name": "CPU_TEMP", "ReadingCelsius": 42.0, "UpperThresholdCritical": 95.0},
			{"Name": "MB_TEMP", "ReadingCelsius": 31.0, "UpperThresholdCritical": 75.0},
		},
		"Fans": []map[string]any{
			{"Name": "CPU_FAN1", "Reading": 1200, "ReadingUnits": "RPM"},
			{"Name": "REAR_FAN1", "Reading": 900, "ReadingUnits": "RPM"},
		},
	})
}

// accountETag returns the current ETag string for an account. AMI uses
// quoted strings, often a monotonically bumped integer. We hash the
// current password so a successful PATCH naturally invalidates the
// previous ETag.
func (s *Server) accountETag() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return fmt.Sprintf(`"%x"`, len(s.password)*7919+1)
}

func (s *Server) serveAccountService(w http.ResponseWriter) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, 200, map[string]any{
		"@odata.id":         "/redfish/v1/AccountService",
		"@odata.type":       "#AccountService.v1_3_0.AccountService",
		"Id":                "AccountService",
		"Name":              "Account Service",
		"MinPasswordLength": s.minPasswordLength,
		"MaxPasswordLength": s.maxPasswordLength,
		"Accounts": map[string]any{
			"@odata.id": "/redfish/v1/AccountService/Accounts",
		},
	})
}

func (s *Server) serveGetAccount(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("ETag", s.accountETag())
	writeJSON(w, 200, map[string]any{
		"@odata.id":   r.URL.Path,
		"@odata.etag": s.accountETag(),
		"Id":          "4",
		"UserName":    s.username,
		"RoleId":      "Administrator",
		"Enabled":     true,
	})
}

func (s *Server) serveSetPassword(w http.ResponseWriter, r *http.Request) {
	// MegaRAC requires If-Match on PATCH; absence yields a 428 with
	// the Ami.1.0.PreconditionHeaderMissing error ID — the same one
	// real hardware emits.
	im := r.Header.Get("If-Match")
	if im == "" {
		writeError(w, 428, "Ami.1.0.PreconditionHeaderMissing",
			"The request did not provide the required precondition, such as an If-Match or If-None-Match header.")
		return
	}
	if im != "*" && im != s.accountETag() {
		writeError(w, 412, "Base.1.12.PreconditionFailed",
			"The ETag supplied did not match the ETag required for this resource.")
		return
	}

	buf, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	if err != nil {
		writeError(w, 400, "Base.1.12.MalformedJSON", "could not read body")
		return
	}
	var body struct {
		Password string `json:"Password"`
	}
	if err := json.Unmarshal(buf, &body); err != nil || body.Password == "" {
		writeError(w, 400, "Base.1.12.PropertyValueFormatError", "Password missing or not a string")
		return
	}
	// MegaRAC's policy: enforce min/max length. The MAX rejection
	// is the one ASRock Rack hits in the field (the real BMC also
	// redacts the value and returns "of length N" in the message).
	s.mu.Lock()
	min := s.minPasswordLength
	max := s.maxPasswordLength
	s.mu.Unlock()
	if len(body.Password) < min || len(body.Password) > max {
		writeError(w, 400, "Base.1.12.PropertyValueFormatError",
			fmt.Sprintf("The value 'of length %d' for the property Password is of a different format than the property can accept.", len(body.Password)))
		return
	}
	s.mu.Lock()
	s.password = body.Password
	s.passwordChangeReq = false
	s.mu.Unlock()
	w.WriteHeader(204)
}

func (s *Server) servePower(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ResetType string `json:"ResetType"`
	}
	buf, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	_ = json.Unmarshal(buf, &body)
	s.mu.Lock()
	s.powerLog = append(s.powerLog, body.ResetType)
	switch body.ResetType {
	case "On":
		s.powerState = "On"
	case "ForceOff", "GracefulShutdown":
		s.powerState = "Off"
	case "PowerCycle", "ForceRestart", "GracefulRestart":
		// Real BMCs end up in "On" after a power cycle / restart —
		// briefly off, then back up. Model the final state.
		s.powerState = "On"
	}
	s.mu.Unlock()
	w.WriteHeader(204)
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, id, msg string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]any{
			"@Message.ExtendedInfo": []map[string]any{
				{"MessageId": id, "Message": msg},
			},
			"code":    id,
			"message": msg,
		},
	})
}

func splitURL(u string) (hostport, rest string) {
	const p = "https://"
	if !strings.HasPrefix(u, p) {
		return "", u
	}
	rest = u[len(p):]
	return rest, ""
}

func sval(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func ivalOr(v, def int) int {
	if v == 0 {
		return def
	}
	return v
}

// makeCert produces a self-signed cert whose subject string contains
// "MEGARAC" so VerifyMegaRAC() in the real client accepts the mock.
func makeCert() (*x509.Certificate, []byte, []byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:         "ami.com",
			Organization:       []string{"AMI"},
			OrganizationalUnit: []string{"MEGARAC"},
			Country:            []string{"US"},
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
		DNSNames:              []string{"localhost"},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, nil, err
	}
	cert, _ := x509.ParseCertificate(der)
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	_ = fmt.Sprintf // keep fmt referenced for some compilers
	return cert, certPEM, keyPEM, nil
}
