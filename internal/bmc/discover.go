package bmc

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

// DiscoveryResult is one BMC found on the LAN.
type DiscoveryResult struct {
	Host        string // 192.168.1.54
	CertSubject string // "C=US,O=AMI,OU=MEGARAC,CN=ami.com"
	CertIssuer  string
	IsMegaRAC   bool
}

// DiscoverCIDR scans a CIDR for hosts whose TLS cert subject contains
// "MEGARAC" — the AMI MegaRAC fingerprint. Concurrency is bounded; we
// fan-out 64 dials at a time which is fast on a /24 and stays nice to
// the network.
//
// We dial port 443 only (the BMC web UI). Failed dials and non-TLS
// responses are silently ignored — anything that isn't a BMC just
// won't appear in the result list.
func DiscoverCIDR(ctx context.Context, cidr string) ([]DiscoveryResult, error) {
	ips, err := expandCIDR(cidr)
	if err != nil {
		return nil, err
	}

	const fanout = 64
	sem := make(chan struct{}, fanout)
	var (
		wg  sync.WaitGroup
		mu  sync.Mutex
		out []DiscoveryResult
	)

	for _, ip := range ips {
		sem <- struct{}{}
		wg.Add(1)
		go func(host string) {
			defer wg.Done()
			defer func() { <-sem }()
			res := probeOne(ctx, host)
			if res == nil {
				return
			}
			mu.Lock()
			out = append(out, *res)
			mu.Unlock()
		}(ip)
	}
	wg.Wait()
	return out, nil
}

func probeOne(ctx context.Context, host string) *DiscoveryResult {
	dctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	d := &net.Dialer{Timeout: 2 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", host+":443", &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		return nil
	}
	_ = dctx
	defer conn.Close()
	state := conn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return nil
	}
	cert := state.PeerCertificates[0]
	subj := cert.Subject.String()
	iss := cert.Issuer.String()
	isMR := strings.Contains(strings.ToUpper(subj+iss), "MEGARAC") ||
		strings.Contains(strings.ToUpper(subj+iss), "AMERICAN MEGATRENDS")
	if !isMR {
		// Only return AMI MegaRAC hits — the caller asked for BMCs.
		return nil
	}
	return &DiscoveryResult{
		Host:        host,
		CertSubject: subj,
		CertIssuer:  iss,
		IsMegaRAC:   isMR,
	}
}

// expandCIDR returns every host address in a CIDR, excluding network
// and broadcast. Limited to /22 or smaller to avoid foot-guns.
func expandCIDR(cidr string) ([]string, error) {
	ip, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, fmt.Errorf("parse CIDR %q: %w", cidr, err)
	}
	if ip.To4() == nil {
		return nil, fmt.Errorf("only IPv4 CIDRs are supported")
	}
	ones, bits := ipNet.Mask.Size()
	if bits-ones > 12 {
		return nil, fmt.Errorf("CIDR %q is too large (max /20)", cidr)
	}

	var out []string
	for ip := ip.Mask(ipNet.Mask); ipNet.Contains(ip); incIP(ip) {
		out = append(out, ip.String())
	}
	// Drop network (.0) and broadcast (.255) for /24 etc.
	if len(out) >= 2 {
		out = out[1 : len(out)-1]
	}
	return out, nil
}

func incIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}
