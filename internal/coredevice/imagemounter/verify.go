package imagemounter

import (
	"context"
	"net"
	"net/http"
)

type Variant int

const (
	Personalized Variant = iota + 1
	Cryptex
)

func (v Variant) String() string {
	if v == Cryptex {
		return "Cryptex"
	}
	return "Personalized"
}

func (v Variant) keys() []string {
	if v == Cryptex {
		return []string{"Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume", "Cryptex1,GenericTrustCache", "Cryptex1,GenericDmg"}
	}
	return []string{"LoadableTrustCache", "PersonalizedDMG"}
}

func (v Variant) identity(m *manifest) (buildIdentity, error) {
	if v == Cryptex {
		return m.cryptexIdentity()
	}
	return m.anyPersonalizedIdentity()
}

var httpClient = func() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = (&net.Dialer{}).DialContext
	transport.TLSHandshakeTimeout = 0
	return &http.Client{Transport: transport}
}()

func Verify(ctx context.Context, dir string, variant Variant) error {
	manifest, err := loadManifest(ctx, dir)
	if err != nil {
		return err
	}
	identity, err := variant.identity(manifest)
	if err != nil {
		return err
	}
	for _, key := range variant.keys() {
		file, err := identity.resolve(dir, key)
		if err != nil {
			return err
		}
		if err = file.verify(ctx); err != nil {
			return err
		}
	}
	return nil
}
