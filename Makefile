.PHONY: configuration email typescript swagger copy compile compress inline-css variants-html install clean npm config-description config-default precompile

all: compile

GOESBUILD ?= off
ifeq ($(GOESBUILD), on)
	ESBUILD := esbuild
else
	ESBUILD := npx esbuild
endif
GOBINARY ?= go

CSSVERSION ?= v3
CSS_BUNDLE = $(DATA)/web/css/$(CSSVERSION)bundle.css

VERSION ?= $(shell git describe --exact-match HEAD 2> /dev/null || echo vgit)
VERSION := $(shell echo $(VERSION) | sed 's/v//g')
COMMIT ?= $(shell git rev-parse --short HEAD || echo unknown)
BUILDTIME ?= $(shell date +%s)

UPDATER ?= off
LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.cssVersion=$(CSSVERSION) -X main.buildTimeUnix=$(BUILDTIME) $(if $(BUILTBY),-X 'main.builtBy=$(BUILTBY)',)
ifeq ($(UPDATER), on)
	LDFLAGS := $(LDFLAGS) -X main.updater=binary
else ifneq ($(UPDATER), off)
	LDFLAGS := $(LDFLAGS) -X main.updater=$(UPDATER)
endif



INTERNAL ?= on
TRAY ?= off
E2EE ?= on
TAGS := -tags "

ifeq ($(INTERNAL), on)
	DATA := data
else
	DATA := build/data
	TAGS := $(TAGS) external
endif

ifeq ($(TRAY), on)
	TAGS := $(TAGS) tray
endif

ifeq ($(E2EE), on)
	TAGS := $(TAGS) e2ee
endif

TAGS := $(TAGS)"

OS := $(shell go env GOOS)
ifeq ($(TRAY)$(OS), onwindows)
	LDFLAGS := $(LDFLAGS) -H=windowsgui
endif

DEBUG ?= off
ifeq ($(DEBUG), on)
	SOURCEMAP := --sourcemap
	MINIFY := 
	TYPECHECK := npx tsc -noEmit --project ts/tsconfig.json
	# jank
	COPYTS := rm -r $(DATA)/web/js/ts; cp -r tempts $(DATA)/web/js/ts
	UNCSS := cp $(CSS_BUNDLE) $(DATA)/bundle.css
	# TAILWIND := --content ""
else
	LDFLAGS := -s -w $(LDFLAGS)
	SOURCEMAP :=
	MINIFY := --minify
	COPYTS :=
	TYPECHECK :=
	UNCSS := npx tailwindcss -i $(CSS_BUNDLE) -o $(DATA)/bundle.css --content "html/crash.html"
	# UNCSS := npx uncss $(DATA)/crash.html --csspath web/css --output $(DATA)/bundle.css
	TAILWIND :=
endif

RACE ?= off
ifeq ($(RACE), on)
	RACEDETECTOR := -race
else
	RACEDETECTOR :=
endif

ifeq (, $(shell which esbuild))
	ESBUILDINSTALL := go install github.com/evanw/esbuild/cmd/esbuild@latest
else
	ESBUILDINSTALL :=
endif

ifeq ($(GOESBUILD), on)
	NPMIGNOREOPTIONAL := --no-optional
	NPMOPTS := $(NPMIGNOREOPTIONAL); $(ESBUILDINSTALL)
else
	NPMOPTS :=
endif

ifeq (, $(shell which swag))
	SWAGINSTALL := $(GOBINARY) install github.com/swaggo/swag/cmd/swag@latest
else
	SWAGINSTALL :=
endif

CONFIG_BASE = config/config-base.yaml

# CONFIG_DESCRIPTION = $(DATA)/config-base.json
CONFIG_DEFAULT = $(DATA)/config-default.ini
# $(CONFIG_DESCRIPTION) &: $(CONFIG_BASE)
# 	$(info Fixing config-base)
# 	-mkdir -p $(DATA)

$(DATA):
	mkdir -p $(DATA)

$(CONFIG_DEFAULT): $(DATA) $(CONFIG_BASE)
	$(info Generating config-default.ini)
	go run scripts/ini/main.go -in $(CONFIG_BASE) -out $(DATA)/config-default.ini

configuration: $(CONFIG_DEFAULT)

EMAIL_SRC_MJML = $(wildcard mail/*.mjml)
EMAIL_SRC_TXT = $(wildcard mail/*.txt)
EMAIL_DATA_MJML = $(EMAIL_SRC_MJML:mail/%=data/%)
EMAIL_HTML = $(EMAIL_DATA_MJML:.mjml=.html)
EMAIL_TXT = $(EMAIL_SRC_TXT:mail/%=data/%)
EMAIL_ALL = $(EMAIL_HTML) $(EMAIL_TXT)
EMAIL_TARGET = mail/confirmation.html
$(EMAIL_TARGET): $(EMAIL_SRC_MJML) $(EMAIL_SRC_TXT)
	$(info Generating email html)
	npx mjml mail/*.mjml -o $(DATA)/
	$(info Copying plaintext mail)
	cp mail/*.txt $(DATA)/

TYPESCRIPT_FULLSRC = $(shell find ts/ -type f -name "*.ts")
TYPESCRIPT_SRC = $(wildcard ts/*.ts)
TYPESCRIPT_TEMPSRC = $(TYPESCRIPT_SRC:ts/%=tempts/%)
# TYPESCRIPT_TARGET = $(patsubst %.ts,%.js,$(subst tempts/,./$(DATA)/web/js/,$(TYPESCRIPT_TEMPSRC)))
TYPESCRIPT_TARGET = $(DATA)/web/js/admin.js
$(TYPESCRIPT_TARGET): $(TYPESCRIPT_FULLSRC) ts/tsconfig.json
	$(TYPECHECK)
	rm -rf tempts
	cp -r ts tempts
	$(adding dark variants to typescript)
	scripts/dark-variant.sh tempts
	scripts/dark-variant.sh tempts/modules
	$(info compiling typescript)
	mkdir -p $(DATA)/web/js
	$(foreach tempsrc,$(TYPESCRIPT_TEMPSRC),$(ESBUILD) --target=es6 --bundle $(tempsrc) $(SOURCEMAP) --outfile=$(patsubst %.ts,%.js,$(subst tempts/,./$(DATA)/web/js/,$(tempsrc))) $(MINIFY);)
	mv $(DATA)/web/js/crash.js $(DATA)/
	$(COPYTS)

SWAGGER_SRC = $(wildcard api*.go) $(wildcard *auth.go) views.go
SWAGGER_TARGET = docs/docs.go
$(SWAGGER_TARGET): $(SWAGGER_SRC)
	$(SWAGINSTALL)
	swag init -g main.go

VARIANTS_SRC = $(wildcard html/*.html)
VARIANTS_TARGET = $(DATA)/html/admin.html
$(VARIANTS_TARGET): $(VARIANTS_SRC)
	$(info copying html)
	cp -r html $(DATA)/
	$(info adding dark variants to html)
	node scripts/missing-colors.js html $(DATA)/html

ICON_SRC = node_modules/remixicon/fonts/remixicon.css node_modules/remixicon/fonts/remixicon.woff2
ICON_TARGET = $(ICON_SRC:node_modules/remixicon/fonts/%=$(DATA)/web/css/%)
CSS_SRC = $(wildcard css/*.css)
CSS_TARGET = $(DATA)/web/css/part-bundle.css
CSS_FULLTARGET = $(CSS_BUNDLE)
ALL_CSS_SRC = $(ICON_SRC) $(CSS_SRC)
ALL_CSS_TARGET = $(ICON_TARGET)

$(CSS_FULLTARGET): $(TYPESCRIPT_TARGET) $(VARIANTS_TARGET) $(ALL_CSS_SRC) $(wildcard html/*.html)
	mkdir -p $(DATA)/web/css
	$(info copying fonts)
	cp -r node_modules/remixicon/fonts/remixicon.css node_modules/remixicon/fonts/remixicon.woff2 $(DATA)/web/css/
	$(info bundling css)
	$(ESBUILD) --bundle css/base.css --outfile=$(CSS_TARGET) --external:remixicon.css --external:../fonts/hanken* --minify

	npx tailwindcss -i $(CSS_TARGET) -o $(CSS_FULLTARGET) $(TAILWIND)
	rm $(CSS_TARGET)
	# mv $(CSS_BUNDLE) $(DATA)/web/css/$(CSSVERSION)bundle.css
	# npx postcss -o $(CSS_TARGET) $(CSS_TARGET)

INLINE_SRC = html/crash.html
INLINE_TARGET = $(DATA)/crash.html
$(INLINE_TARGET): $(CSS_FULLTARGET) $(INLINE_SRC)
	cp html/crash.html $(DATA)/crash.html
	$(UNCSS) # generates $(DATA)/bundle.css for us
	node scripts/inline.js root $(DATA) $(DATA)/crash.html $(DATA)/crash.html
	rm $(DATA)/bundle.css

LANG_SRC = $(shell find ./lang)
LANG_TARGET = $(LANG_SRC:lang/%=$(DATA)/lang/%)
STATIC_SRC = $(wildcard static/*)
STATIC_TARGET = $(STATIC_SRC:static/%=$(DATA)/web/%)
COPY_SRC = images/banner.svg jfa-go.service LICENSE $(LANG_SRC) $(STATIC_SRC)
COPY_TARGET = $(DATA)/jfa-go.service
# $(DATA)/LICENSE $(LANG_TARGET) $(STATIC_TARGET) $(DATA)/web/css/$(CSSVERSION)bundle.css
$(COPY_TARGET): $(INLINE_TARGET) $(STATIC_SRC) $(LANG_SRC)
	$(info copying $(CONFIG_BASE))
	cp $(CONFIG_BASE) $(DATA)/
	$(info copying crash page)
	cp $(DATA)/crash.html $(DATA)/html/
	$(info copying static data)
	mkdir -p $(DATA)/web
	cp images/banner.svg static/banner.svg
	cp -r static/* $(DATA)/web/
	$(info copying systemd service)
	cp jfa-go.service $(DATA)/
	$(info copying language files)
	cp -r lang $(DATA)/
	cp LICENSE $(DATA)/

precompile: $(CONFIG_DEFAULT) $(EMAIL_TARGET) $(COPY_TARGET) $(SWAGGER_TARGET)

GO_SRC = $(shell find ./ -name "*.go")
GO_TARGET = build/jfa-go
$(GO_TARGET): $(CONFIG_DEFAULT) $(EMAIL_TARGET) $(COPY_TARGET) $(SWAGGER_TARGET) $(GO_SRC) go.mod go.sum
	$(info Downloading deps)
	$(GOBINARY) mod download
	$(info Building)
	mkdir -p build
	$(GOBINARY) build $(RACEDETECTOR) -ldflags="$(LDFLAGS)" $(TAGS) -o $(GO_TARGET)

compile: $(GO_TARGET)

compress:
	upx --lzma build/jfa-go

install:
	cp -r build $(DESTDIR)/jfa-go

clean:
	-rm -r $(DATA)
	-rm -r build
	-rm mail/*.html
	-rm docs/docs.go docs/swagger.json docs/swagger.yaml
	go clean

npm:
	$(info installing npm dependencies)
	npm install $(NPMOPTS)
