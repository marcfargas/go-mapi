module github.com/marcfargas/go-mapi/service

go 1.23

require (
	github.com/marcfargas/go-mapi/internal/mapi v0.0.0
	golang.org/x/sys v0.30.0
)

replace github.com/marcfargas/go-mapi/internal/mapi => ../../internal/mapi
