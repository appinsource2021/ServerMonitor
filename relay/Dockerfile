FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /srvmon-relay .
RUN mkdir /data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /srvmon-relay /srvmon-relay
# the relay runs as nonroot: without this the volume starts root-owned and relay.json cannot be written
COPY --from=build --chown=65532:65532 /data /data
ENV RELAY_ADDR=:8080 RELAY_DATA=/data
VOLUME /data
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/srvmon-relay"]
