module github.com/marcfargas/go-mapi/native-host

go 1.23

require github.com/marcfargas/go-mapi/internal/mapi v0.0.0

require (
	github.com/fsnotify/fsnotify v1.9.0 // indirect
	golang.org/x/sys v0.30.0 // indirect
)

replace github.com/marcfargas/go-mapi/internal/mapi v0.0.0 => ../../internal/mapi
