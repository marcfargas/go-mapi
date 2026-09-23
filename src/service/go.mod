module github.com/marcfargas/go-mapi/service

go 1.23

require (
	github.com/marcfargas/go-mapi/internal/mapi v0.0.0
	golang.org/x/sys v0.30.0
)

require (
	github.com/Masterminds/semver/v3 v3.4.0 // indirect
	github.com/fsnotify/fsnotify v1.9.0 // indirect
)

replace github.com/marcfargas/go-mapi/internal/mapi => ../../internal/mapi
