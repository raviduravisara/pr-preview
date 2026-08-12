FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /ttl-cleanup .

FROM scratch
COPY --from=build /ttl-cleanup /ttl-cleanup
ENTRYPOINT ["/ttl-cleanup"]
