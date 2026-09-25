package main

import (
	"net/http"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func newAppUpdateEngine() *update.Engine {
	engine, err := update.NewEngine(update.Config{
		SKU:            update.App,
		MetadataOrigin: "https://go-mapi.app",
		Client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}},
		Now: time.Now,
	})
	if err != nil {
		logError("updates: initialise engine: %v", err)
	}
	return engine
}
