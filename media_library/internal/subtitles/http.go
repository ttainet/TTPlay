package subtitles

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"ttplay/media_library/internal/db"
)

const (
	maxUpstreamBodyBytes = 12 * 1024 * 1024
	httpClientTimeout    = 15 * time.Second
	defaultUserAgent     = "TTPlay/1.0"
)

type sfCall struct {
	wg  sync.WaitGroup
	val any
	err error
}

type sfGroup struct {
	mu sync.Mutex
	m  map[string]*sfCall
}

func (g *sfGroup) Do(key string, fn func() (any, error)) (any, error) {
	g.mu.Lock()
	if g.m == nil {
		g.m = make(map[string]*sfCall)
	}
	if c, ok := g.m[key]; ok {
		g.mu.Unlock()
		c.wg.Wait()
		return c.val, c.err
	}
	c := &sfCall{}
	c.wg.Add(1)
	g.m[key] = c
	g.mu.Unlock()

	defer func() {
		g.mu.Lock()
		delete(g.m, key)
		g.mu.Unlock()
		c.wg.Done()
	}()

	c.val, c.err = fn()
	return c.val, c.err
}

func (s *Service) httpClientForProxy(proxyRaw string) (*http.Client, error) {
	proxyKey := strings.TrimSpace(proxyRaw)
	s.httpMu.Lock()
	defer s.httpMu.Unlock()
	if cli, ok := s.httpClients[proxyKey]; ok {
		return cli, nil
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if proxyKey != "" {
		proxyURL, err := db.ParseProxyURL(proxyKey)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrUpstream, err)
		}
		tr.Proxy = http.ProxyURL(proxyURL)
	}
	cli := &http.Client{
		Timeout:   httpClientTimeout,
		Transport: tr,
	}
	s.httpClients[proxyKey] = cli
	return cli, nil
}

func (s *Service) doRequestBytes(
	ctx context.Context,
	method string,
	rawURL string,
	proxyRaw string,
	headers map[string]string,
	reqBody any,
) ([]byte, http.Header, int, error) {
	cli, err := s.httpClientForProxy(proxyRaw)
	if err != nil {
		return nil, nil, 0, err
	}
	var bodyReader io.Reader
	if reqBody != nil {
		b, mErr := json.Marshal(reqBody)
		if mErr != nil {
			return nil, nil, 0, mErr
		}
		bodyReader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, bodyReader)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if _, ok := headers["Accept"]; !ok {
		req.Header.Set("Accept", "application/json, text/plain, */*")
	}
	if _, ok := headers["User-Agent"]; !ok {
		req.Header.Set("User-Agent", defaultUserAgent)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := cli.Do(req)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxUpstreamBodyBytes+1))
	if err != nil {
		return nil, resp.Header, resp.StatusCode, fmt.Errorf("%w: %v", ErrUpstream, err)
	}
	if len(body) > maxUpstreamBodyBytes {
		return nil, resp.Header, resp.StatusCode, fmt.Errorf("%w: upstream payload exceeds limit", ErrUpstream)
	}
	return body, resp.Header, resp.StatusCode, nil
}

func validateExternalHTTPURL(raw string, allowLoopback bool) error {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return fmt.Errorf("%w: invalid url", ErrInvalidInput)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("%w: unsupported url scheme %q", ErrInvalidInput, u.Scheme)
	}
	host := strings.ToLower(strings.TrimSpace(u.Hostname()))
	if host == "" {
		return fmt.Errorf("%w: missing url host", ErrInvalidInput)
	}
	if !allowLoopback {
		if host == "localhost" {
			return fmt.Errorf("%w: loopback host disallowed", ErrInvalidInput)
		}
		if ip := net.ParseIP(host); ip != nil {
			if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
				return fmt.Errorf("%w: private ip disallowed", ErrInvalidInput)
			}
		}
	}
	return nil
}
